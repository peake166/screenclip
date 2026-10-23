import Foundation
import CoreGraphics

// All OCR rectangles use screenshot pixels, with their origin at the top left.
struct OCRLine: Equatable {
    let text: String
    let rect: CGRect
}

struct OCRBlock: Equatable {
    let id: Int
    let text: String
    let lines: [CGRect]
    var rect: CGRect { lines.reduce(CGRect.null) { $0.union($1) } }
}

struct OCRDocument: Equatable {
    let imageSize: CGSize
    let blocks: [OCRBlock]
    var text: String { blocks.map(\.text).joined(separator: "\n\n") }
}

enum TextLayout {
    static func document(lines: [OCRLine], imageSize: CGSize) -> OCRDocument {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let valid = lines.compactMap { line -> OCRLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rect = line.rect.intersection(bounds)
            guard !text.isEmpty, !rect.isNull, rect.width > 0, rect.height > 0 else { return nil }
            return OCRLine(text: text, rect: rect)
        }.sorted {
            if abs($0.rect.minY - $1.rect.minY) < min($0.rect.height, $1.rect.height) * 0.35 {
                return $0.rect.minX < $1.rect.minX
            }
            return $0.rect.minY < $1.rect.minY
        }
        var paragraphs: [[OCRLine]] = []
        for line in valid {
            var best: Int?, distance = CGFloat.greatestFiniteMagnitude
            for index in paragraphs.indices {
                guard let last = paragraphs[index].last else { continue }
                let gap = line.rect.minY - last.rect.maxY
                let height = min(line.rect.height, last.rect.height)
                let ratio = max(line.rect.height, last.rect.height) / max(1, height)
                let aligned = abs(line.rect.minX - paragraphs[index][0].rect.minX) <= max(10, height * 0.7)
                guard !startsListItem(line.text), aligned, ratio < 1.35,
                      gap >= -height * 0.2, gap <= height * 0.85, gap < distance else { continue }
                best = index; distance = gap
            }
            if let best { paragraphs[best].append(line) } else { paragraphs.append([line]) }
        }
        let blocks = paragraphs.enumerated().map { index, lines in
            OCRBlock(id: index, text: lines.map(\.text).joined(separator: " "), lines: lines.map(\.rect))
        }
        return OCRDocument(imageSize: imageSize, blocks: blocks)
    }
    static func localRect(_ pixels: CGRect, imageSize: CGSize, viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGRect(x: pixels.minX * viewSize.width / imageSize.width,
                      y: pixels.minY * viewSize.height / imageSize.height,
                      width: pixels.width * viewSize.width / imageSize.width,
                      height: pixels.height * viewSize.height / imageSize.height)
    }
    private static func startsListItem(_ text: String) -> Bool {
        text.range(of: #"^([•●▪\-*]|[0-9]+[.)、])\s"#, options: .regularExpression) != nil
    }
}
