// Interactive local fixture. Launch separately to exercise the installed app's
// real hotkeys, selection, scrolling, capture and clipboard without private data.
import AppKit
import Vision

private final class DailyRows: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for row in 0..<80 {
            let rect = CGRect(x: 0, y: row * 72, width: Int(bounds.width), height: 72)
            guard rect.intersects(dirtyRect) else { continue }
            NSColor(calibratedHue: CGFloat(row % 19) / 19, saturation: 0.14,
                    brightness: row % 2 == 0 ? 1 : 0.95, alpha: 1).setFill(); rect.fill()
            (String(format: "ROW %02d  Unique content %04d", row, row * 137 + 31) as NSString).draw(
                at: CGPoint(x: 20, y: row * 72 + 10), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold), .foregroundColor: NSColor.black])
            ("A daily capture keeps every complete line in its original order." as NSString).draw(
                at: CGPoint(x: 20, y: row * 72 + 43), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.darkGray])
            for x in 0..<12 {
                NSColor(calibratedHue: CGFloat((row * 7 + x * 3) % 37) / 37,
                        saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                CGRect(x: 600 + (x % 4) * 12, y: row * 72 + 12 + (x / 4) * 14, width: 8, height: 9).fill()
            }
        }
    }
}

private final class FixedFooter: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.12, green: 0.22, blue: 0.32, alpha: 1).setFill(); bounds.fill()
        ("DAILY FIXTURE END" as NSString).draw(at: CGPoint(x: 20, y: 13), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 23, weight: .semibold), .foregroundColor: NSColor.white])
    }
}

private final class DailyFixtureDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private let status = NSTextField(labelWithString: "本机生成的截图测试内容 · 不含个人数据")
    private var originalClipboard: [[(NSPasteboard.PasteboardType, Data)]] = []
    private var lastTestClipboardCount: Int?
    private var checkIndex = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        originalClipboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let menu = NSMenu(), item = NSMenuItem(), actions = NSMenu()
        actions.addItem(withTitle: "退出测试并还原剪贴板", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = actions; menu.addItem(item); NSApp.mainMenu = menu
        let screen = NSScreen.main!.visibleFrame
        window = NSWindow(contentRect: CGRect(x: screen.minX + 90, y: screen.minY + 70, width: 760, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "截图助手日常流程测试（生成内容）"; window.isReleasedWhenClosed = false
        let content = window.contentView!
        status.frame = CGRect(x: 24, y: 603, width: 712, height: 28)
        status.font = .systemFont(ofSize: 16, weight: .medium); content.addSubview(status)
        scroll = NSScrollView(frame: CGRect(x: 24, y: 80, width: 712, height: 500))
        scroll.hasVerticalScroller = true
        scroll.documentView = DailyRows(frame: CGRect(x: 0, y: 0, width: 690, height: 5760))
        content.addSubview(scroll)
        let footer = FixedFooter(frame: CGRect(x: 24, y: 80, width: 690, height: 48))
        content.addSubview(footer)
        for (title, action, x) in [("回到顶部", #selector(top), 24.0),
                                   ("向下 240 点", #selector(down), 184.0),
                                   ("检查剪贴板", #selector(checkClipboard), 344.0)] {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.frame = CGRect(x: x, y: 24, width: 144, height: 32)
            content.addSubview(button)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func top() { move(0) }
    @objc private func down() { move(scroll.contentView.bounds.minY + 240) }
    private func move(_ position: CGFloat) {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: position)); scroll.reflectScrolledClipView(scroll.contentView)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func checkClipboard() {
        do {
            guard let data = NSPasteboard.general.data(forType: .png), let image = NSBitmapImageRep(data: data)?.cgImage
            else { status.stringValue = "未取得 PNG 截图"; return }
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }
            let footerCount = lines.filter { $0.contains("DAILY FIXTURE END") }.count
            // Do not save, log or inspect arbitrary clipboard images.
            guard footerCount > 0 else { status.stringValue = "剪贴板不是本测试窗口，未保存"; return }
            let pattern = try NSRegularExpression(pattern: #"ROW\s+(\d{2})"#)
            let rows = lines.compactMap { line -> Int? in
                let range = NSRange(line.startIndex..., in: line)
                guard let found = pattern.firstMatch(in: line, range: range),
                      let value = Range(found.range(at: 1), in: line) else { return nil }
                return Int(line[value])
            }
            let offset = Int(scroll.contentView.bounds.minY)
            let expectedRows = Array(0..<((offset + 452) / 72))
            let result: [String: Any] = ["width": image.width, "height": image.height,
                "scrollOffsetPoints": offset, "footerOccurrences": footerCount,
                "rows": rows, "expectedCompleteRows": expectedRows,
                "allExpectedRowsPresentOnce": expectedRows.allSatisfy { value in rows.filter { $0 == value }.count == 1 },
                "rowsInOrder": rows == rows.sorted() && Set(rows).count == rows.count,
                "footerPresentOnce": footerCount == 1,
                "scope": "generated content from the real installed helper flow; no translation provider call"]
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-daily-e2e")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            checkIndex += 1
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("check-\(checkIndex).json"))
            try data.write(to: directory.appendingPathComponent("check-\(checkIndex).png"))
            lastTestClipboardCount = NSPasteboard.general.changeCount
            status.stringValue = "已检查 \(image.width) × \(image.height) · \(rows.count) 行 · 底栏 \(footerCount) 次"
        } catch { status.stringValue = "检查失败：\(error.localizedDescription)" }
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard NSPasteboard.general.changeCount == lastTestClipboardCount else { return }
        let items = originalClipboard.map { pairs -> NSPasteboardItem in
            let item = NSPasteboardItem(); for (type, data) in pairs { item.setData(data, forType: type) }; return item
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects(items)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main enum DailyCaptureFixture {
    static func main() {
        let app = NSApplication.shared, delegate = DailyFixtureDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
    }
}
