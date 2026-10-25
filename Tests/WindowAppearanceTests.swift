import AppKit

@main struct WindowAppearanceTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let window = MainWindow(icon: nil)
        window.contentView!.layoutSubtreeIfNeeded()
        let root = window.contentView!
        let close = all(root).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "关闭窗口" }
        check(close != nil && close?.isHiddenOrHasHiddenAncestor == false && close?.isEnabled == true,
              "the main window has a visible, enabled close control inside its glass surface")
        if let close {
            let rect = close.convert(close.bounds, to: root)
            check(rect.minX >= 10 && rect.maxX < 48 && rect.maxY <= root.bounds.maxY - 8 && rect.minY >= root.bounds.maxY - 40,
                  "the close control remains in the familiar upper-left corner")
            let point = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: close.superview)
            check(close.hitTest(point) != nil, "the glass does not intercept clicks on the close control")
            window.orderFront(nil); close.performClick(nil)
            check(!window.isVisible, "clicking close hides the main window")
        }
        window.close()
        for dark in [false, true] {
            let surface = FrostedSurface(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
            let host = NSWindow(contentRect: surface.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false; host.contentView = surface
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            host.appearance = appearance; surface.appearance = appearance
            surface.layoutSubtreeIfNeeded()
            let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
            appearance.performAsCurrentDrawingAppearance { surface.cacheDisplay(in: surface.bounds, to: bitmap) }
            let alpha = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent ?? 1
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            check(reduce ? alpha >= 0.98 : alpha < 0.85,
                  "\(dark ? "dark" : "light") glass \(reduce ? "honors reduced transparency" : "keeps the background translucent")")
            check(!host.isOpaque && host.backgroundColor.alphaComponent == 0 && surface.alphaValue == 1,
                  "only the background is translucent; foreground controls keep full opacity")
            host.close()
        }
        if failures > 0 { print("\(failures) window appearance checks failed"); exit(1) }
        print("Window appearance checks passed without changing system appearance settings")
    }
}
