import AppKit
import Vision

@main struct OCRTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        func makeImage(height: Int, lines: [(String, Int)], fontSize: CGFloat = 36, dark: Bool = false) -> CGImage {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            (dark ? NSColor.black : NSColor.white).setFill(); NSRect(x: 0, y: 0, width: 1200, height: height).fill()
            for (text, top) in lines {
                (text as NSString).draw(at: NSPoint(x: 32, y: height - top - 50), withAttributes: [
                    .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: dark ? NSColor.white : NSColor.black
                ])
            }
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.cgImage!
        }
        let small = makeImage(height: 360, lines: [("Hello world.", 30), ("Please copy this text.", 120), ("你好，世界。", 220)])
        let result = try TextRecognizer.recognizeImage(small)
        check(result.contains("Hello world.") && result.contains("Please copy this text."), "Vision recognizes real English text from pixels")
        check(result.contains("你好") && result.contains("世界"), "Vision recognizes Chinese text locally")
        let dark = makeImage(height: 240, lines: [("Settings and privacy", 20), ("复制文字并翻译", 90)], fontSize: 18, dark: true)
        let darkResult = try TextRecognizer.recognizeImage(dark)
        if !darkResult.contains("Settings and privacy") || !darkResult.contains("复制文字并翻译") { print("Dark fixture result: \(darkResult)") }
        check(darkResult.contains("Settings and privacy") && darkResult.contains("复制文字并翻译"),
              "small Chinese and English text remains readable on a dark background")
        let markers = (1...60).map { String(format: "Section %02d. This is a long screenshot.", $0) }
        let long = makeImage(height: 6000, lines: markers.enumerated().map { ($0.element, 30 + $0.offset * 96) })
        let longResult = try TextRecognizer.recognizeImage(long)
        var previous = longResult.startIndex
        var ordered = true
        for index in 1...60 {
            let marker = String(format: "Section %02d.", index)
            let occurrences = longResult.components(separatedBy: marker).count - 1
            guard occurrences == 1, let range = longResult.range(of: marker), range.lowerBound >= previous else {
                ordered = false; print("Marker \(index): \(occurrences) occurrences"); continue
            }
            previous = range.upperBound
        }
        check(ordered, "tiled long-image OCR preserves every line once in reading order")
        let blank = makeImage(height: 200, lines: [])
        do { _ = try TextRecognizer.recognizeImage(blank); check(false, "a blank image reports no text") }
        catch TranslationFailure.noText { check(true, "a blank image reports no text") }
        if failures > 0 { print("\(failures) OCR checks failed"); exit(1) }
        print("All OCR checks passed")
    }
}
