import AppKit

final class RowsView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirty: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        for row in 0..<90 {
            let rect = CGRect(x: 0, y: row * 72, width: Int(bounds.width), height: 72)
            guard rect.intersects(dirty) else { continue }
            NSColor(calibratedHue: CGFloat(row % 19) / 19, saturation: 0.15, brightness: row % 2 == 0 ? 1 : 0.95, alpha: 1).setFill()
            rect.fill()
            let title = String(format: "ROW %02d   Unique content %04d", row, row * 137 + 31)
            (title as NSString).draw(at: CGPoint(x: 24, y: row * 72 + 12),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 18, weight: .medium), .foregroundColor: NSColor.black])
            let text = "Frame stitching checks continuity, color, and complete image rows."
            (text as NSString).draw(at: CGPoint(x: 24, y: row * 72 + 41),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
            for column in 0..<12 {
                NSColor(calibratedHue: CGFloat((row * 7 + column * 3) % 37) / 37, saturation: 0.8, brightness: 0.8, alpha: 1).setFill()
                CGRect(x: 590 + (column % 4) * 12, y: row * 72 + 12 + (column / 4) * 14, width: 8, height: 9).fill()
            }
        }
    }
}

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var scroll: NSScrollView!
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: CGRect(x: 120, y: 110, width: 760, height: 700),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Screenshot continuity fixture"
        window.isReleasedWhenClosed = false
        let view = window.contentView!
        let label = NSTextField(labelWithString: "截图测试页 — 每行有唯一编号与颜色")
        label.frame = CGRect(x: 26, y: 652, width: 708, height: 26)
        label.font = .systemFont(ofSize: 19, weight: .semibold); view.addSubview(label)
        scroll = NSScrollView(frame: CGRect(x: 26, y: 82, width: 708, height: 548))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        scroll.documentView = RowsView(frame: CGRect(x: 0, y: 0, width: 686, height: 6480))
        view.addSubview(scroll)
        let buttons: [(String, Selector, CGFloat)] = [("回到顶部", #selector(top), 26), ("向下 240 点", #selector(down), 182), ("向上 120 点", #selector(up), 338)]
        for (title, action, x) in buttons {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded; button.frame = CGRect(x: x, y: 23, width: 144, height: 34)
            view.addSubview(button)
        }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func top() { move(0) }
    @objc func down() { move(scroll.contentView.bounds.minY + 240) }
    @objc func up() { move(max(0, scroll.contentView.bounds.minY - 120)) }
    func move(_ y: CGFloat) {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let fixtureDelegate = FixtureDelegate()
app.delegate = fixtureDelegate
app.run()
