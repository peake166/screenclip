import Foundation
import Vision
import CoreGraphics
import CoreText
import OSLog

// The lock protects every mutable field shared by the worker and the cancellation handler.
final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    func install(_ request: VNRequest) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        self.request = request
    }
    func clear() { lock.lock(); request = nil; lock.unlock() }
    func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        let active = request; request = nil
        lock.unlock(); active?.cancel()
    }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

enum TextRecognizer {
    private static let queue = DispatchQueue(label: "com.local.screenclip.ocr", qos: .userInitiated)
    private static let logger = Logger(subsystem: "com.local.screenclip", category: "OCR")
    private static let warmLock = NSLock()
    private static var warmScheduled = false
    private static var userRequested = false
    private static let languages: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? ["en-US"]
        return ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR"].filter { supported.contains($0) }
    }()

    static func warmUp() {
        warmLock.lock()
        guard !warmScheduled else { warmLock.unlock(); return }
        warmScheduled = true; warmLock.unlock()
        queue.asyncAfter(deadline: .now() + 3, qos: .utility) {
            warmLock.lock(); let skip = userRequested; warmLock.unlock()
            guard !skip, let image = warmUpImage() else { return }
            let start = Date()
            logger.notice("OCR warm-up started")
            do {
                _ = try recognizeImage(image)
                logger.notice("OCR warm-up completed; milliseconds: \(Int(Date().timeIntervalSince(start) * 1000))")
            } catch {
                let native = error as NSError
                logger.error("OCR warm-up failed: domain=\(native.domain, privacy: .public); code=\(native.code)")
            }
        }
    }

    static func recognize(_ raster: Raster) async throws -> String {
        try await recognizeDocument(raster).text
    }

    static func recognizeDocument(_ raster: Raster, maximumCharacters: Int? = TranslationText.maximumCharacters) async throws -> OCRDocument {
        warmLock.withLock { userRequested = true }
        let cancellation = OCRCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    let start = Date()
                    do {
                        try cancellation.check()
                        let result = try recognizeDocumentImage(raster.cgImage(), cancellation: cancellation, maximumCharacters: maximumCharacters)
                        logger.notice("OCR completed; size: \(raster.width)x\(raster.height); milliseconds: \(Int(Date().timeIntervalSince(start) * 1000))")
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private static func warmUpImage() -> CGImage? {
        guard let context = CGContext(data: nil, width: 360, height: 90, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 360, height: 90))
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Ready 识别就绪", attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 28, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]))
        context.textPosition = CGPoint(x: 16, y: 30); CTLineDraw(line, context)
        return context.makeImage()
    }

    static func recognizeImage(_ image: CGImage, cancellation: OCRCancellation? = nil) throws -> String {
        try recognizeDocumentImage(image, cancellation: cancellation).text
    }

    static func recognizeDocumentImage(_ image: CGImage, cancellation: OCRCancellation? = nil,
                                       maximumCharacters: Int? = TranslationText.maximumCharacters) throws -> OCRDocument {
        var lines: [OCRLine] = []
        let tileHeight = 1800, overlap = 180
        for coreTop in stride(from: 0, to: image.height, by: tileHeight) {
            try Task.checkCancellation()
            try cancellation?.check()
            let coreBottom = min(coreTop + tileHeight, image.height)
            let top = max(0, coreTop - overlap), bottom = min(image.height, coreBottom + overlap)
            guard let tile = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            request.recognitionLanguages = languages
            try cancellation?.install(request)
            defer { cancellation?.clear() }
            try VNImageRequestHandler(cgImage: normalizedDarkTile(tile)).perform([request])
            try Task.checkCancellation()
            try cancellation?.check()
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let box = observation.boundingBox
                let lineTop = CGFloat(top) + (1 - box.maxY) * CGFloat(tile.height)
                let lineBottom = CGFloat(top) + (1 - box.minY) * CGFloat(tile.height)
                let center = (lineTop + lineBottom) / 2
                // Only the central band owns a line. The overlaps give OCR context without duplicating content.
                guard center >= CGFloat(coreTop), center < CGFloat(coreBottom) else { continue }
                lines.append(OCRLine(text: text, rect: CGRect(x: box.minX * CGFloat(image.width), y: lineTop,
                    width: box.width * CGFloat(image.width), height: lineBottom - lineTop)))
            }
        }
        guard !lines.isEmpty else { throw TranslationFailure.noText }
        let document = TextLayout.document(lines: lines, imageSize: CGSize(width: image.width, height: image.height))
        if let maximumCharacters, document.text.count > maximumCharacters { throw TranslationFailure.tooLong }
        return document
    }

    private static func normalizedDarkTile(_ image: CGImage) -> CGImage {
        var sample = [UInt8](repeating: 0, count: 16 * 16 * 4)
        let isDark = sample.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 16, height: 16))
            var dark = 0
            for index in stride(from: 0, to: bytes.count, by: 4) {
                if Int(bytes[index]) + Int(bytes[index + 1]) + Int(bytes[index + 2]) < 192 { dark += 1 }
            }
            return dark > 153
        }
        guard isDark,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        // Normalize dark UI text to dark-on-light without changing the captured image or its size.
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setBlendMode(.difference); context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        return context.makeImage() ?? image
    }

}
