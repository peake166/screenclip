import AppKit
import CoreGraphics
import Foundation

enum CaptureError: LocalizedError {
    case invalidImage, missingDisplay, invalidSelection, noImage, busy
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取截图，请重新框选。"
        case .missingDisplay: return "显示器已断开，请重新选择截图区域。"
        case .invalidSelection: return "截图区域太小，请重新框选。"
        case .noImage: return "还没有可复制的截图。"
        case .busy: return "截图正在处理中，请稍后重试。"
        }
    }
}

struct Raster {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width; self.height = height; self.bytes = bytes
    }

    init(_ image: CGImage) throws {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw CaptureError.invalidImage }
        self.init(width: w, height: h, bytes: pixels)
    }

    func gray() -> GrayFrame {
        let sampleWidth = min(112, width)
        var result = [UInt8](repeating: 0, count: sampleWidth * height)
        for y in 0..<height {
            for x in 0..<sampleWidth {
                let column = min(width - 1, (x * width + width / 2) / sampleWidth)
                let i = (y * width + column) * 4
                result[y * sampleWidth + x] = UInt8((Int(bytes[i]) * 77 + Int(bytes[i+1]) * 150 + Int(bytes[i+2]) * 29) >> 8)
            }
        }
        return GrayFrame(width: sampleWidth, height: height, pixels: result)
    }

    func bottom(_ rows: Int) -> Raster {
        let count = min(height, max(0, rows))
        return Raster(width: width, height: count, bytes: Array(bytes[((height - count) * width * 4)..<bytes.count]))
    }

    func cgImage() throws -> CGImage {
        guard width > 0, height > 0, bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw CaptureError.invalidImage }
        return image
    }

    static func join(_ strips: [Raster]) throws -> Raster {
        guard let first = strips.first else { throw CaptureError.noImage }
        guard strips.allSatisfy({ $0.width == first.width && $0.bytes.count == $0.width * $0.height * 4 })
        else { throw CaptureError.invalidImage }
        let height = strips.reduce(0) { $0 + $1.height }
        var data = [UInt8](); data.reserveCapacity(first.width * height * 4)
        for strip in strips { data.append(contentsOf: strip.bytes) }
        return Raster(width: first.width, height: height, bytes: data)
    }

    func png() throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: try cgImage()).representation(using: .png, properties: [:])
        else { throw CaptureError.invalidImage }
        return data
    }
}

enum ImageClipboard {
    // Encode before clearing: an encoding error must leave the old clipboard intact.
    static func copy(_ image: Raster, to board: NSPasteboard = .general) throws {
        let png = try image.png()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        board.clearContents()
        guard board.writeObjects([item]) else { throw CaptureError.invalidImage }
    }
}
