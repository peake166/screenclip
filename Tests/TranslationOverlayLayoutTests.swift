import AppKit

@main struct TranslationOverlayLayoutTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)"); if !value { failures += 1 }
        }
        let image = Raster(width: 800, height: 400, bytes: Array(repeating: [UInt8(245), 245, 245, 255], count: 800 * 400).flatMap { $0 })
        let doc = OCRDocument(imageSize: CGSize(width: 800, height: 400), blocks: [
            OCRBlock(id: 0, text: "Title", lines: [CGRect(x: 40, y: 30, width: 250, height: 40)]),
            OCRBlock(id: 1, text: "Body", lines: [CGRect(x: 40, y: 100, width: 400, height: 28)])
        ])
        let rendered = TranslationOverlayLayout.placements(document: doc, translations: [0: "翻译标题", 1: "正文译文"], image: image, size: CGSize(width: 400, height: 200))
        check(rendered.count == 2, "each completed block produces one translated placement")
        if let title = rendered.first, let body = rendered.last {
            check(abs(title.frame.minX - 20) <= 2 && abs(title.frame.minY - 15) <= 2, "text is placed over the original heading at Retina scale")
            check(title.frame.maxY <= body.frame.minY, "a heading does not cover the following paragraph")
            check(title.fontSize > body.fontSize && body.fontSize >= 9, "heading hierarchy is retained without unreadably small type")
            check(title.foreground == NSColor.black, "a light source background receives contrasting dark text")
        }
        let longText = String(repeating: "A complete long translation must remain available. ", count: 200)
        let long = TranslationOverlayLayout.placements(document: doc, translations: [0: longText], image: image, size: CGSize(width: 400, height: 200))
        check(long.first?.overflow == true && long.first?.text == longText, "an oversized translation is marked for expansion and never discarded")
        check(long.allSatisfy { CGRect(x: 0, y: 0, width: 400, height: 200).contains($0.frame) && $0.frame.maxY <= 49 },
              "long text stays inside the screenshot and clear of the next text block")
        let shortLabel = OCRDocument(imageSize: CGSize(width: 800, height: 400), blocks: [
            OCRBlock(id: 9, text: "Label", lines: [CGRect(x: 40, y: 100, width: 90, height: 28)])
        ])
        let labelLayout = TranslationOverlayLayout.placements(document: shortLabel, translations: [9: longText], image: image, size: CGSize(width: 400, height: 200))
        let sourceArea = CGRect(x: 18, y: 48, width: 49, height: 18)
        check(labelLayout.allSatisfy { sourceArea.contains($0.frame) } && labelLayout.count == 1,
              "expanded translations cannot paint over icons or artwork outside the original text area")
        let dark = Raster(width: 800, height: 400, bytes: Array(repeating: [UInt8(20), 20, 20, 255], count: 800 * 400).flatMap { $0 })
        let darkLayout = TranslationOverlayLayout.placements(document: doc, translations: [0: "深色译文"], image: dark, size: CGSize(width: 400, height: 200))
        check(darkLayout.first?.foreground == NSColor.white, "a dark screenshot retains a dark cover and readable light text")
        let pending = TranslationOverlayLayout.placements(document: doc, translations: [:], image: image, size: CGSize(width: 400, height: 200))
        check(pending.isEmpty, "untranslated text remains visible while translation is pending")
        if failures > 0 { exit(1) }
    }
}
