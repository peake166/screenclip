import AppKit

struct OverlayPlacement {
    let id: Int
    let text: String
    let frame: CGRect
    let covers: [CGRect]
    let fontSize: CGFloat
    let overflow: Bool
    let background: NSColor
    var foreground: NSColor {
        let rgb = background.usingColorSpace(.deviceRGB) ?? .white
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.55 ? .black : .white
    }
}

@MainActor enum TranslationOverlayLayout {
    static func placements(document: OCRDocument, translations: [Int: String], image: Raster, size: CGSize) -> [OverlayPlacement] {
        let bounds = CGRect(origin: .zero, size: size)
        let rects = document.blocks.map { TextLayout.localRect($0.rect, imageSize: document.imageSize, viewSize: size) }
        return document.blocks.enumerated().compactMap { index, block in
            guard let text = translations[block.id], !text.isEmpty, text != block.text else { return nil }
            let source = rects[index]
            let covers = block.lines.map {
                TextLayout.localRect($0, imageSize: document.imageSize, viewSize: size).insetBy(dx: -2, dy: -2).intersection(bounds)
            }
            var frame = source.insetBy(dx: -2, dy: -2).intersection(bounds)
            guard !frame.isNull, frame.width > 0, frame.height > 0 else { return nil }
            var bottom = size.height
            var right = size.width
            for (otherIndex, other) in rects.enumerated() where otherIndex != index {
                if other.minY >= source.maxY - 1, other.maxX > frame.minX, other.minX < frame.maxX {
                    bottom = min(bottom, other.minY - 2)
                }
                if other.minX >= source.maxX - 1, other.maxY > source.minY, other.minY < source.maxY {
                    right = min(right, other.minX - 2)
                }
            }
            // Only OCR text areas may be painted. Whitespace can contain icons or artwork that OCR cannot describe.
            frame.size.width = max(1, min(frame.width, right - frame.minX))
            let availableHeight = max(1, min(frame.height, bottom - frame.minY))
            let heights = block.lines.map { $0.height * size.height / document.imageSize.height }.sorted()
            var font = min(42, max(9, (heights[heights.count / 2]) * 1.15))
            var needed = height(text, width: frame.width, font: font)
            while needed > availableHeight, font > 9 {
                font = max(9, font - 0.5); needed = height(text, width: frame.width, font: font)
            }
            frame.size.height = min(availableHeight, max(frame.height, needed))
            frame = frame.intersection(bounds)
            return OverlayPlacement(id: block.id, text: text, frame: frame, covers: covers, fontSize: font,
                overflow: needed > frame.height + 0.5, background: background(image, rects: block.lines))
        }
    }

    static func height(_ text: String, width: CGFloat, font: CGFloat) -> CGFloat {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: font)
        field.maximumNumberOfLines = 0
        return ceil(field.cell!.cellSize(forBounds: CGRect(x: 0, y: 0, width: max(1, width), height: 100_000)).height) + 2
    }

    private static func background(_ image: Raster, rects: [CGRect]) -> NSColor {
        // Perimeter sampling avoids the glyphs. The most common quantized color resists border/icon noise.
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for rect in rects {
            for step in 0..<20 {
                let t = CGFloat(step) / 19
                for point in [CGPoint(x: rect.minX + rect.width * t, y: rect.minY - 2),
                              CGPoint(x: rect.minX + rect.width * t, y: rect.maxY + 2)] {
                    let x = min(image.width - 1, max(0, Int(point.x)))
                    let y = min(image.height - 1, max(0, Int(point.y)))
                    let i = (y * image.width + x) * 4
                    guard i + 2 < image.bytes.count else { continue }
                    let r = Int(image.bytes[i]), g = Int(image.bytes[i + 1]), b = Int(image.bytes[i + 2])
                    let key = (r / 16) * 256 + (g / 16) * 16 + b / 16
                    let old = buckets[key] ?? (0, 0, 0, 0)
                    buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
                }
            }
        }
        guard let value = buckets.values.max(by: { $0.count < $1.count }), value.count > 0 else { return .white }
        let divisor = CGFloat(value.count) * 255
        return NSColor(srgbRed: CGFloat(value.r) / divisor, green: CGFloat(value.g) / divisor, blue: CGFloat(value.b) / divisor, alpha: 1)
    }
}
