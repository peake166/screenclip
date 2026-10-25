import Foundation

@main struct ClipboardHistoryStoreTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-history-tests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var failures = 0
        func fixtureStore(_ directory: URL) throws -> ClipboardHistoryStore {
            try ClipboardHistoryStore(directory: directory, encryptionKey: Data(repeating: 0x42, count: 32))
        }
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)"); if !condition { failures += 1 }
        }
        func snapshot(_ text: String) -> ClipboardSnapshot {
            ClipboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]])
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let store = try fixtureStore(directory)
        let id = try store.insert(snapshot("fixture 中文 searchable"), applicationName: "Fixture", applicationID: "test.fixture", now: now)
        check(id != nil && store.entries.count == 1, "copied content becomes one history item")
        if let id {
            check(try store.read(id) == snapshot("fixture 中文 searchable"), "history retains complete original representations")
            try store.setPinned(id, true)
            let duplicate = try store.insert(snapshot("fixture 中文 searchable"), applicationName: "Other", applicationID: "test.other", now: now.addingTimeInterval(1))
            check(duplicate == id && store.entries.count == 1 && store.entries.first?.pinned == true,
                  "duplicates move the same entry while preserving its pin")
            let reloaded = try fixtureStore(directory)
            check(reloaded.entries.count == 1 && reloaded.entries.first?.pinned == true,
                  "history and pins survive a fresh store instance")
            check(store.matching("中文").count == 1 && store.matching("fixture").count == 1 && store.matching("missing").isEmpty,
                  "search finds Chinese text and source applications")
            store.maximumCount = 2
            _ = try store.insert(snapshot("second"), applicationName: "Fixture", applicationID: "", now: now.addingTimeInterval(2))
            _ = try store.insert(snapshot("third"), applicationName: "Fixture", applicationID: "", now: now.addingTimeInterval(3))
            check(store.entries.count == 2 && store.entries.contains(where: { $0.id == id }) && !store.entries.contains(where: { $0.text == "second" }),
                  "count limits evict old unpinned entries and keep pins")
            store.retentionDays = 7
            try store.prune(now: now.addingTimeInterval(8 * 86400))
            check(store.entries.count == 1 && store.entries.first?.id == id, "expiry removes old unpinned content while pins remain")
            try store.remove(id)
            let afterDelete = try fixtureStore(directory)
            check(store.entries.isEmpty && afterDelete.entries.isEmpty,
                  "deletion persists after restart")
        } else {
            for label in ["history round trip", "deduplication", "restart", "search", "count pruning", "expiry", "deletion"] { check(false, label) }
        }
        let limited = try fixtureStore(directory.appendingPathComponent("limited"))
        limited.maximumBytes = 8
        let first = try limited.insert(snapshot("12345678"), applicationName: "Fixture", applicationID: "", now: now)
        if let first {
            try limited.setPinned(first, true)
            do {
                _ = try limited.insert(snapshot("new"), applicationName: "Fixture", applicationID: "", now: now)
                check(false, "a full pinned history reports capacity instead of silently dropping new content")
            } catch ClipboardHistoryFailure.full { check(true, "a full pinned history reports capacity instead of silently dropping new content") }
            check(limited.entries.count == 1 && limited.entries.first?.id == first, "capacity failure preserves existing history")
        } else { check(false, "capacity setup accepts a fitting payload") }
        try limited.clear(includingPinned: true)
        check(limited.entries.isEmpty, "clear includes pinned items")
        let files = (try? FileManager.default.contentsOfDirectory(at: limited.directory, includingPropertiesForKeys: nil)) ?? []
        check(files.filter { ["plist", "clip"].contains($0.pathExtension) }.isEmpty, "clear removes stored clipboard payloads")
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        check((attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o700, "history storage is private to the current user")
        let corrupt = directory.appendingPathComponent("corrupt")
        try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
        try Data("not a manifest".utf8).write(to: corrupt.appendingPathComponent("history.json"))
        do { _ = try fixtureStore(corrupt); check(false, "corrupt history is not silently overwritten") }
        catch { check(true, "corrupt history is not silently overwritten") }
        let longStore = try fixtureStore(directory.appendingPathComponent("long-text"))
        let long = snapshot(String(repeating: "你好🌟", count: 15_000))
        if let id = try longStore.insert(long, applicationName: "Fixture", applicationID: "") {
            check(longStore.entries[0].text.utf8.count <= 20_000 && !longStore.entries[0].text.contains("\u{fffd}"),
                  "large Unicode text has a bounded valid search index")
            check(try longStore.read(id) == long, "bounded search indexing preserves the complete copyable payload")
        } else { check(false, "long text remains available") }
        if failures > 0 { print("\(failures) history store checks failed"); exit(1) }
        print("All history store checks passed using synthetic data")
    }
}
