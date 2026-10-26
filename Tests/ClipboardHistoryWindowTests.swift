import AppKit

@main struct ClipboardHistoryWindowTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-history-ui-" + UUID().uuidString)
        let suite = "com.local.screenclip.clipboard-ui." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let history = ClipboardHistory(board: board, defaults: defaults, directory: folder,
            encryptionKey: Data(repeating: 0x42, count: 32), source: { ("Test Editor", "test.editor") })
        await history.flush()
        let window = ClipboardHistoryWindow(history: history)
        defer { window.close() }
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func button(_ label: String) -> NSButton { all(window.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }! }
        let primary = button("使用选中的剪贴板内容")
        let search = all(window.contentView!).compactMap { $0 as? NSSearchField }.first!
        let table = all(window.contentView!).compactMap { $0 as? NSTableView }.first!
        func entryRows() -> [Int] { (0..<table.numberOfRows).filter { window.tableView(table, shouldSelectRow: $0) } }
        check(window.styleMask.contains(.nonactivatingPanel), "clipboard picker preserves the original active application")
        check(!primary.isEnabled && !history.settings.isRecording, "empty history has no action and starts paused")
        button("暂停或开启剪贴板记录").performClick(nil)
        board.clearContents(); board.setString("Clipboard fixture 中文 — searchable note", forType: .string); history.poll(); await history.flush()
        board.clearContents(); board.setString("A second fixture", forType: .string); history.poll(); await history.flush()
        window.refresh()
        check(entryRows().count == 2 && primary.isEnabled, "copied records appear as selectable entries below date headings")
        search.stringValue = "中文"; window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification)); await window.waitForSearch()
        check(entryRows().count == 1, "background search narrows the visible results")
        button("置顶或取消置顶").performClick(nil); await history.flush(); window.refresh(); await window.waitForSearch()
        check(history.matching("中文").first?.pinned == true, "pinning affects exactly the selected result")
        var actions: [ClipboardPrimaryAction] = []; window.onAction = { actions.append($0) }
        let editor = NSTextView()
        _ = window.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await history.flush()
        check(actions == [.paste] && board.string(forType: .string)?.contains("中文") == true,
              "Return restores the original data and requests paste into the target application")
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        check(window.performKeyEquivalent(with: enter), "Command Return is handled independently of the default action")
        await history.flush()
        check(actions == [.paste, .copy], "Command Return copies without requesting an automatic paste")
        var copySettings = history.settings; copySettings.primaryAction = .copy; history.updateSettings(copySettings); await history.flush()
        window.refresh(); await window.waitForSearch()
        primary.performClick(nil); await history.flush()
        check(actions.last == .copy, "the optional copy-only default is honored by the primary action")
        button("置顶或取消置顶").performClick(nil); await history.flush(); window.refresh(); await window.waitForSearch()
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{8}", charactersIgnoringModifiers: "\u{8}", isARepeat: false, keyCode: 51)!
        _ = window.performKeyEquivalent(with: delete); await history.flush(); window.refresh(); await window.waitForSearch()
        check(entryRows().isEmpty && !primary.isEnabled && history.entries.count == 1,
              "deleting a filtered ordinary result keeps unrelated history")
        search.stringValue = ""; window.refresh()
        let image = NSImage(size: NSSize(width: 200, height: 100))
        image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 200, height: 100).fill(); image.unlockFocus()
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        board.clearContents(); board.setData(png, forType: .png); history.poll(); await history.flush(); window.refresh()
        table.selectRowIndexes(IndexSet(integer: entryRows().first!), byExtendingSelection: false)
        window.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification)); await history.flush()
        let preview = all(window.contentView!).compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "剪贴板图片预览" }!
        check(preview.image != nil && !preview.isHidden, "background image loading produces a bounded preview")
        let filters = all(window.contentView!).compactMap { $0 as? NSSegmentedControl }.first!
        filters.selectedSegment = 2; filters.sendAction(filters.action, to: filters.target)
        check(entryRows().count == 1, "image filter hides text records")
        filters.selectedSegment = 0; filters.sendAction(filters.action, to: filters.target)
        button("暂停或开启剪贴板记录").performClick(nil); await history.flush(); window.refresh()
        check(!history.settings.isRecording, "recording can be paused directly from the picker")
        search.stringValue = "second"; window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        _ = window.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await window.waitForSearch(); await history.flush()
        check(board.string(forType: .string) == "A second fixture" && actions.last == .copy,
              "Return pressed during a background search uses the matching result instead of a stale selection")
        search.stringValue = ""; window.refresh()
        var draft: ClipboardHistorySettings?
        let settings = ClipboardHistorySettingsWindow(settings: history.settings); settings.onSave = { draft = $0 }
        let controls = all(settings.contentView!)
        let time = controls.compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "历史保留时间" }!
        time.selectItem(at: 1)
        controls.compactMap { $0 as? NSButton }.first { $0.title == "保存" }!.performClick(nil)
        check(draft?.retentionDays == 7 && draft?.primaryAction == .copy && draft?.excludedApplications == history.settings.excludedApplications,
              "preference changes preserve the action choice and excluded applications")
        settings.close()
        let previews = URL(fileURLWithPath: ".build/clipboard-1.7/previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            window.appearance = appearance; window.contentView!.appearance = appearance
            window.contentView!.layoutSubtreeIfNeeded()
            let bounds = window.contentView!.bounds
            check(bounds.width <= 800 && bounds.height <= 540, "picker retains a compact window")
            for control in all(window.contentView!).compactMap({ $0 as? NSButton }) where !control.isHiddenOrHasHiddenAncestor {
                let rect = control.convert(control.bounds, to: window.contentView!)
                check(control.bounds.width > 5 && control.bounds.height > 5 && bounds.insetBy(dx: -1, dy: -1).contains(rect),
                      "visible picker control is not clipped: \(control.accessibilityLabel() ?? control.title)")
            }
            check(table.enclosingScrollView!.frame.height > 200 && table.enclosingScrollView!.frame.width > 280,
                  "history list has a useful viewport in \(dark ? "dark" : "light") appearance")
            let detail = all(window.contentView!).compactMap { $0 as? ReadableSurface }.first!
            let detailRect = detail.convert(detail.bounds, to: window.contentView!)
            check(detailRect.width > 300 && abs(detailRect.maxX - (bounds.maxX - 16)) < 1,
                  "preview fills the available trailing pane instead of collapsing to its intrinsic text width")
            for (name, pane) in [("history list", table.enclosingScrollView! as NSView), ("content preview", detail as NSView)] {
                let pixels = pane.bitmapImageRepForCachingDisplay(in: pane.bounds)!
                appearance.performAsCurrentDrawingAppearance { pane.cacheDisplay(in: pane.bounds, to: pixels) }
                let x = Int(12 * CGFloat(pixels.pixelsWide) / pane.bounds.width)
                let samples = [pixels.pixelsHigh / 2, pixels.pixelsHigh - 20].map { pixels.colorAt(x: x, y: $0)!.alphaComponent }
                check(samples.allSatisfy { $0 > 0.99 },
                      "\(dark ? "dark" : "light") \(name) has an opaque reading background")
            }
            let view = window.contentView!
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                func invalidate(_ view: NSView) { view.needsDisplay = true; view.subviews.forEach(invalidate) }
                for _ in 0..<8 {
                    invalidate(view)
                    appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                }
                // A window-backed visual effect can composite desktop pixels into an opaque bitmap.
                // Verify the live glass configuration; its isolated rendering is covered by WindowAppearanceTests.
                let glass = all(view).compactMap { $0 as? NSVisualEffectView }.first
                let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
                check(view is FrostedSurface && !window.isOpaque && window.backgroundColor.alphaComponent == 0
                      && window.alphaValue == 1 && view.alphaValue == 1 && glass?.blendingMode == .behindWindow
                      && glass?.isHidden == reduce && (glass?.alphaValue ?? 1) < 1,
                      "the outer picker chrome keeps its glass treatment independently of reading panes")
                try bitmap.representation(using: .png, properties: [:])!.write(to: previews.appendingPathComponent("clipboard-\(dark ? "dark" : "light").png"))
            }
        }
        await history.flush()
        if failures > 0 { print("\(failures) clipboard UI checks failed"); exit(1) }
        print("Clipboard UI checks passed with synthetic data and a private pasteboard; no native paste events posted")
    }
}
