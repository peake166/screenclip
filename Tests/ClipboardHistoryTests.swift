import AppKit

@main struct ClipboardHistoryTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let board = NSPasteboard.withUniqueName()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-monitor-" + UUID().uuidString)
        let suite = "com.local.screenclip.clipboard.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: folder); defaults.removePersistentDomain(forName: suite) }
        var failures = 0
        func check(_ condition: Bool, _ label: String) { print("\(condition ? "PASS" : "FAIL") \(label)"); if !condition { failures += 1 } }
        func put(_ string: String) { board.clearContents(); board.setString(string, forType: .string) }
        put("before-start fixture")
        var source = (name: "Fixture", id: "test.fixture")
        let history = ClipboardHistory(board: board, defaults: defaults, directory: folder, encryptionKey: Data(repeating: 0x42, count: 32), source: { source })
        history.poll(); await history.flush()
        check(!history.settings.isRecording && history.entries.isEmpty, "new installations do not read existing clipboard content")
        history.setRecording(true); history.poll(); await history.flush()
        check(history.settings.isRecording && history.entries.isEmpty, "enabling starts with future copies rather than importing the old clipboard")
        put("new text"); history.poll(); await history.flush()
        check(history.entries.count == 1 && history.entries.first?.text == "new text", "new text reaches persistent searchable history")
        history.poll(); await history.flush()
        check(history.entries.count == 1, "a clipboard change is handled only once")
        history.setRecording(false); put("while paused"); history.poll(); await history.flush()
        check(history.entries.count == 1, "paused content is ignored")
        history.setRecording(true); history.poll(); await history.flush()
        check(!history.entries.contains(where: { $0.text == "while paused" }), "resuming does not backfill paused copies")
        var settings = history.settings
        settings.excludedApplications["test.excluded"] = "Excluded"
        history.updateSettings(settings)
        source = ("Excluded", "test.excluded")
        put("excluded text"); history.poll(); await history.flush()
        check(!history.entries.contains(where: { $0.text == "excluded text" }), "excluded applications are filtered before capture")
        source = ("Fixture", "test.fixture")
        put("second text"); history.poll(); await history.flush()
        check(history.entries.contains(where: { $0.text == "second text" }), "other applications continue to be recorded")
        if let entry = history.entries.first {
            let copied = await withCheckedContinuation { continuation in history.copy(entry.id) { continuation.resume(returning: $0) } }
            await history.flush()
            check(copied && board.string(forType: .string) == entry.text, "history selection really restores the clipboard")
            let count = history.entries.count
            history.poll(); await history.flush()
            check(history.entries.count == count, "copying history does not create a feedback loop")
        } else { check(false, "history selection restores the clipboard"); check(false, "history copy loop") }
        history.setRecording(false)
        let reloaded = ClipboardHistory(board: board, defaults: defaults, directory: folder, encryptionKey: Data(repeating: 0x42, count: 32), source: { source })
        check(!reloaded.settings.isRecording && reloaded.settings.excludedApplications["test.excluded"] == "Excluded",
              "pause and excluded-app settings persist across relaunch")
        check(reloaded.entries.count == 2, "recorded history persists across relaunch")
        await reloaded.flush()
        reloaded.clear(); await reloaded.flush()
        check(reloaded.entries.isEmpty, "clear updates the history view without changing clipboard content")
        let legacySettings = try JSONSerialization.data(withJSONObject: ["isRecording": false, "retentionDays": 7,
            "maximumCount": 200, "excludedApplications": ["test.private": "Private App"]])
        let upgraded = try JSONDecoder().decode(ClipboardHistorySettings.self, from: legacySettings)
        check(upgraded.retentionDays == 30 && upgraded.maximumCount == 5000 && upgraded.primaryAction == .paste
            && !upgraded.isRecording && upgraded.excludedApplications["test.private"] == "Private App",
            "legacy defaults upgrade without enabling recording or losing app exclusions")
        var custom = upgraded; custom.retentionDays = 7; custom.maximumCount = 1000; custom.primaryAction = .copy; custom.pasteAsPlainText = true
        let restored = try JSONDecoder().decode(ClipboardHistorySettings.self, from: JSONEncoder().encode(custom))
        check(restored == custom, "newly chosen seven-day retention, copy action and plain-text preference survive relaunch")
        if failures > 0 { print("\(failures) history monitor checks failed"); exit(1) }
        print("All clipboard monitor checks passed; system clipboard untouched")
    }
}
