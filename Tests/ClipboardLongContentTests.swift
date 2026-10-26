import AppKit

@main struct ClipboardLongContentTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-long-content-" + UUID().uuidString)
        let suite = "com.local.screenclip.long-content." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var applicationName = "Fixture Editor"
        let history = ClipboardHistory(board: board, defaults: defaults, directory: folder,
            encryptionKey: Data(repeating: 0x42, count: 32), source: { (applicationName, "fixture.editor") })
        await history.flush(); history.setRecording(true); await history.flush()
        let window = ClipboardHistoryWindow(history: history)
        defer {
            history.stop(); history.onChange = nil; window.close(); board.releaseGlobally()
            try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite)
        }
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let root = window.contentView!
        let table = all(root).compactMap { $0 as? NSTableView }.first!
        let text = all(root).compactMap { $0 as? NSTextView }.first!
        let image = all(root).compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "剪贴板图片预览" }!
        let initialSize = window.frame.size
        func layout() { root.layoutSubtreeIfNeeded(); text.layoutManager?.ensureLayout(for: text.textContainer!) }
        func checkBounds(_ label: String) {
            layout()
            let size = window.frame.size, fitting = root.fittingSize
            check(size.width <= 700.5 && size.height <= 480.5 && fitting.width <= 700.5 && fitting.height <= 480.5,
                  "\(label) stays within window bounds (frame \(Int(size.width))x\(Int(size.height)), fitting \(Int(fitting.width))x\(Int(fitting.height)))")
            check(abs(size.width - initialSize.width) < 1 && abs(size.height - initialSize.height) < 1,
                  "\(label) does not resize the picker")
            check(table.enclosingScrollView!.bounds.width > 250 && table.enclosingScrollView!.bounds.width < 350,
                  "\(label) keeps the list within its compact viewport")
        }
        func select(_ id: UUID) async {
            window.refresh()
            let rows = (0..<table.numberOfRows).filter { window.tableView(table, shouldSelectRow: $0) }
            let index = history.entries.firstIndex { $0.id == id }!
            table.selectRowIndexes(IndexSet(integer: rows[index]), byExtendingSelection: false)
            table.scrollRowToVisible(rows[index])
            window.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
            await history.flush(); layout()
        }
        let copy = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        let samples = [
            ("long Chinese paragraph", String(repeating: "这是用于验证剪贴板布局的测试段落，窗口应保持紧凑并完整保留文字。", count: 100)),
            ("unbroken URL", "https://example.invalid/" + String(repeating: "long-path-segment", count: 300)),
            ("many lines", (0..<600).map { "Line \($0): synthetic clipboard content" }.joined(separator: "\n")),
            ("short text after long content", "Short fixture")
        ]
        for (label, value) in samples {
            board.clearContents(); board.setString(value, forType: .string); history.poll(); await history.flush()
            let entry = history.entries.max { $0.copiedAt < $1.copiedAt }!
            await select(entry.id)
            checkBounds(label)
            let clip = text.enclosingScrollView!.contentView.bounds
            let used = text.layoutManager!.usedRect(for: text.textContainer!)
            check(text.string == value && text.frame.width <= clip.width + 1 && used.width <= clip.width + 1,
                  "\(label) wraps the full preview inside its viewport")
            if label != "short text after long content" {
                check(used.height > clip.height, "\(label) scrolls vertically rather than growing the window")
            }
            if let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) {
                let name = all(cell).compactMap { $0 as? NSTextField }.first!
                check(name.bounds.width > 100 && name.bounds.width < 250 && name.bounds.height < 25
                      && name.lineBreakMode == .byTruncatingTail,
                      "\(label) has a bounded single-line list title")
            } else { check(false, "\(label) has a visible list row") }
            board.clearContents(); board.setString("Sentinel", forType: .string)
            _ = window.performKeyEquivalent(with: copy); await history.flush()
            check(board.string(forType: .string) == value, "\(label) copies the original untruncated content")
        }
        applicationName = String(repeating: "Very Long Application Name ", count: 8)
        board.clearContents(); board.setString("Long source name fixture", forType: .string); history.poll(); await history.flush()
        await select(history.entries.first { $0.text == "Long source name fixture" }!.id)
        checkBounds("long source application name")
        for (width, height) in [(6000, 120), (120, 6000)] {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            board.clearContents(); board.setData(png, forType: .png); history.poll(); await history.flush()
            await select(history.entries.first { $0.hasImage }!.id)
            checkBounds("\(width)x\(height) image")
            check(image.image != nil && !image.isHidden && image.frame.width < 350 && image.frame.height < 350,
                  "large images fit inside the preview")
            board.clearContents(); board.setString("Sentinel", forType: .string)
            _ = window.performKeyEquivalent(with: copy); await history.flush()
            check(board.data(forType: .png) == png, "large image copying preserves original pixels")
        }
        await select(history.entries.first { $0.text == samples[0].1 }!.id)
        for size in [NSSize(width: 600, height: 400), NSSize(width: 700, height: 480), initialSize] {
            window.setContentSize(size); layout()
            check(window.frame.size == size && root.bounds.size == size,
                  "manual resizing to \(Int(size.width))x\(Int(size.height)) remains available with long content")
            let clip = text.enclosingScrollView!.contentView.bounds
            check(text.layoutManager!.usedRect(for: text.textContainer!).width <= clip.width + 1,
                  "long preview reflows after manual resizing")
            let buttons = all(root).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            check(buttons.allSatisfy {
                $0.bounds.width > 5 && $0.bounds.height > 5
                    && root.bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: root))
            }, "all controls remain visible at the supported window size")
        }
        let previews = URL(fileURLWithPath: ".build/clipboard-bounds-1.9.4/previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            window.appearance = appearance; root.appearance = appearance; layout(); table.scrollRowToVisible(table.selectedRow)
            let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds)!
            func invalidate(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(invalidate) }
            for _ in 0..<8 {
                invalidate(root)
                appearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            }
            try bitmap.representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent("long-content-\(dark ? "dark" : "light").png"))
        }
        if failures > 0 { print("\(failures) long-content checks failed"); exit(1) }
        print("Long-content checks passed without opening windows or using the system clipboard")
    }
}
