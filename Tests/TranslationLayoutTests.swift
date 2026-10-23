import Foundation

@main struct TranslationLayoutTests {
    static func main() {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)"); if !value { failures += 1 }
        }
        let lines = [
            OCRLine(text: "right second", rect: CGRect(x: 430, y: 66, width: 210, height: 20)),
            OCRLine(text: "left first", rect: CGRect(x: 30, y: 40, width: 280, height: 20)),
            OCRLine(text: "Heading", rect: CGRect(x: 30, y: 5, width: 190, height: 30)),
            OCRLine(text: "right first", rect: CGRect(x: 430, y: 40, width: 230, height: 20)),
            OCRLine(text: "left second", rect: CGRect(x: 30, y: 66, width: 240, height: 20)),
            OCRLine(text: "New paragraph", rect: CGRect(x: 30, y: 115, width: 230, height: 20))
        ]
        let doc = TextLayout.document(lines: lines, imageSize: CGSize(width: 800, height: 300))
        check(doc.blocks.count == 4, "headings, columns and separated paragraphs remain distinct")
        check(doc.blocks.contains { $0.text == "left first left second" && $0.lines.count == 2 }, "wrapped paragraph lines translate together")
        check(doc.blocks.contains { $0.text == "right first right second" }, "two columns never become one translation block")
        check(doc.blocks.map(\.id) == Array(0..<doc.blocks.count), "block identities are unique and stable in reading order")
        check(doc.blocks.first?.rect == lines[2].rect, "the first heading retains its actual position")
        let list = TextLayout.document(lines: [
            OCRLine(text: "1. First item", rect: CGRect(x: 20, y: 10, width: 200, height: 20)),
            OCRLine(text: "2. Second item", rect: CGRect(x: 20, y: 36, width: 200, height: 20))
        ], imageSize: CGSize(width: 300, height: 100))
        check(list.blocks.count == 2, "separate list items keep their own positions")
        let mapped = TextLayout.localRect(CGRect(x: 200, y: 80, width: 400, height: 40),
            imageSize: CGSize(width: 1600, height: 1000), viewSize: CGSize(width: 800, height: 500))
        check(mapped == CGRect(x: 100, y: 40, width: 200, height: 20), "Retina coordinates map to the original point position without a vertical flip")
        let clipped = TextLayout.document(lines: [
            OCRLine(text: "edge", rect: CGRect(x: -2, y: 95, width: 140, height: 20)),
            OCRLine(text: " ", rect: CGRect(x: 20, y: 30, width: 30, height: 10))
        ], imageSize: CGSize(width: 100, height: 100))
        check(clipped.blocks.count == 1 && clipped.blocks[0].rect == CGRect(x: 0, y: 95, width: 100, height: 5),
              "OCR boxes are clipped to the screenshot and empty text is excluded")
        if failures > 0 { exit(1) }
    }
}
