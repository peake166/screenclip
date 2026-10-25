import AppKit

@main struct ClipboardPickerInteractionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-picker-interactions-" + UUID().uuidString)
        let suite = "com.local.screenclip.picker-interactions." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        let history = ClipboardHistory(board: board, defaults: defaults, directory: folder,
            encryptionKey: Data(repeating: 0x42, count: 32), source: { ("Fixture Editor", "test.editor") })
        await history.flush(); history.setRecording(true); await history.flush()
        for number in 0..<12 {
            board.clearContents(); board.setString("Older pinned fixture \(number)", forType: .string)
            history.poll(); await history.flush()
            history.setPinned(history.entries.first(where: { $0.text == "Older pinned fixture \(number)" })!.id, true)
            await history.flush()
        }
        let newest = "Most recent ordinary fixture"
        board.clearContents(); board.setString(newest, forType: .string); history.poll(); await history.flush()
        let window = ClipboardHistoryWindow(history: history)
        defer { history.onChange = nil; window.close() }
        history.onChange = { [weak window] in window?.refresh() }
        var requestedActions: [ClipboardPrimaryAction] = []
        window.onAction = { requestedActions.append($0) }
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let search = all(window.contentView!).compactMap { $0 as? NSSearchField }.first!
        let table = all(window.contentView!).compactMap { $0 as? NSTableView }.first!
        let filters = all(window.contentView!).compactMap { $0 as? NSSegmentedControl }.first!
        let editor = NSTextView()
        func title(at row: Int) -> String? {
            guard row >= 0, let cell = window.tableView(table, viewFor: table.tableColumns[0], row: row) else { return nil }
            return all(cell).compactMap { $0 as? NSTextField }.first?.stringValue
        }
        func selectedTitle() -> String? { title(at: table.selectedRow) }
        func openPicker() { window.present(targetName: "Fixture Editor"); window.contentView!.layoutSubtreeIfNeeded() }
        search.stringValue = "Older pinned"; filters.selectedSegment = 3
        window.refresh(); await window.waitForSearch()
        openPicker()
        check(search.stringValue.isEmpty && filters.selectedSegment == 0, "opening resets the prior search and content filter")
        check(selectedTitle() == newest, "opening selects the newest copy instead of an older pinned item")
        let newestRow = (0..<table.numberOfRows).first { title(at: $0) == newest }!
        let selectedRect = table.rect(ofRow: newestRow), viewport = table.visibleRect
        check(selectedRect.minY >= viewport.minY - 1 && selectedRect.maxY <= viewport.maxY + 1,
              "the newest item is visible below a long pinned section without manual scrolling")
        _ = window.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        check(selectedTitle() != newest, "the user can navigate away from the initial newest item")
        window.dismiss(); openPicker()
        check(selectedTitle() == newest, "reopening forgets the previous older selection")

        let immediate = "Copied immediately before opening"
        board.clearContents(); board.setString(immediate, forType: .string)
        openPicker()
        _ = window.control(search, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await history.flush()
        // The capture write can finish before the queued copy's read/completion callback.
        for _ in 0..<200 {
            if !requestedActions.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await history.flush()
        check(history.entries.contains(where: { $0.text == immediate }), "opening captures a new copy before the polling timer runs")
        check(board.string(forType: .string) == immediate && requestedActions == [.paste],
              "immediate Return waits for the just-copied item instead of pasting the old selection")

        openPicker()
        let pinEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
            windowNumber: 0, context: nil, characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
        check(window.performKeyEquivalent(with: pinEvent), "Shift Command P is handled from the picker search field")
        await history.flush()
        check(history.entries.first(where: { $0.text == immediate })?.pinned == true, "Shift Command P pins exactly the selected item")
        _ = window.performKeyEquivalent(with: pinEvent); await history.flush()
        check(history.entries.first(where: { $0.text == immediate })?.pinned == false, "the same shortcut unpins the selected item")
        let otherModifiers = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35)!
        _ = window.performKeyEquivalent(with: otherModifiers); await history.flush()
        check(history.entries.first(where: { $0.text == immediate })?.pinned == false, "additional modifiers do not accidentally toggle a pin")

        let racing = "New copy while the picker is opening"
        board.clearContents(); board.setString(racing, forType: .string); openPicker()
        _ = window.control(search, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:)))
        let explicitSelection = selectedTitle()
        await history.flush()
        check(selectedTitle() == explicitSelection, "completing an initial capture respects the user's subsequent navigation")
        check(window.frame.width <= 660 && window.frame.height <= 460, "the picker opens at a smaller desktop size")
        check(window.maxSize.width <= 700 && window.maxSize.height <= 480 && window.minSize.width >= 600 && window.minSize.height >= 400,
              "interactive resizing has useful minimum and maximum bounds")
        for size in [NSSize(width: 600, height: 400), NSSize(width: 700, height: 480)] {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
            window.contentView!.layoutSubtreeIfNeeded()
            let bounds = window.contentView!.bounds
            let buttons = all(window.contentView!).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }
            check(buttons.allSatisfy { $0.bounds.width > 5 && $0.bounds.height > 5 && bounds.insetBy(dx: -1, dy: -1).contains($0.convert($0.bounds, to: window.contentView!)) },
                  "actions remain inside the window at \(Int(size.width)) by \(Int(size.height))")
        }
        await history.flush()
        if failures > 0 { print("\(failures) picker interaction checks failed"); exit(1) }
        print("Picker interaction checks passed with synthetic history and a private pasteboard")
    }
}
