import AppKit
import Carbon

@main
struct Preview {
    @MainActor static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let icon = NSImage(contentsOfFile: "Assets/AppIcon-Blue.png")
        let folder = URL(fileURLWithPath: ".build/previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let custom: [ShortcutAction: Shortcut] = [
            .copy: Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "A"),
            .scroll: Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "W"),
            .translate: Shortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "S")
        ]
        for bindings in [Shortcut.defaults, custom] {
        for dark in [false, true] {
            let window = MainWindow(icon: icon)
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            window.appearance = appearance
            window.contentView!.appearance = appearance
            window.update(bindings: bindings, permissionGranted: true)
            for expanded in [false, true] {
                if expanded { window.revealSettings() }
                let view = window.contentView!
                view.layoutSubtreeIfNeeded()
                func verify(_ candidate: NSView) {
                    guard !candidate.isHiddenOrHasHiddenAncestor else { return }
                    if candidate is NSControl, candidate.bounds.width > 0, candidate.bounds.height > 0 {
                        let rect = candidate.convert(candidate.bounds, to: view)
                        if !view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect) {
                            print("FAIL visible control is clipped: \(type(of: candidate)) \(rect)")
                            exit(1)
                        }
                    }
                    candidate.subviews.forEach(verify)
                }
                verify(view)
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No bitmap") }
                for _ in 0..<8 {
                    view.needsDisplay = true
                    appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                }
                let name = "\(dark ? "dark" : "light")-\(expanded ? "settings" : "main")\(bindings == custom ? "-custom" : "").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
                print("Rendered \(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            }
            window.close()
        }
        }
    }
}
