import Foundation

@main struct ClipboardUpgradeTests {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-upgrade-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var failures = 0
        func fixtureStore(_ directory: URL) throws -> ClipboardHistoryStore {
            try ClipboardHistoryStore(directory: directory, encryptionKey: Data(repeating: 0x42, count: 32))
        }
        func check(_ condition: Bool, _ message: String) { print("\(condition ? "PASS" : "FAIL") \(message)"); if !condition { failures += 1 } }
        func snapshot(_ text: String) -> ClipboardSnapshot { .init(items: [[.init(type: "public.utf8-plain-text", data: Data(text.utf8))]]) }
        let now = Date()
        let store = try fixtureStore(folder)
        _ = try store.insert(snapshot("ordinary retention fixture"), applicationName: "Fixture", applicationID: "test", now: now)
        try store.prune(now: now.addingTimeInterval(8 * 86400))
        check(store.entries.count == 1, "ordinary history survives the old seven-day boundary")
        try store.prune(now: now.addingTimeInterval(31 * 86400))
        check(store.entries.isEmpty, "ordinary history expires after thirty days")
        let old = try store.insert(snapshot("pinned fixture"), applicationName: "Fixture", applicationID: "test", now: now.addingTimeInterval(-100 * 86400))!
        try store.setPinned(old, true)
        _ = try store.insert(snapshot("ordinary fixture"), applicationName: "Fixture", applicationID: "test", now: now)
        try store.clear()
        check(store.entries.count == 1 && store.entries.first?.id == old, "ordinary clear protects pinned content")
        if store.entries.contains(where: { $0.id == old }) {
            try store.setPinned(old, false)
            try store.prune(now: now.addingTimeInterval(29 * 86400))
            check(store.entries.contains(where: { $0.id == old }), "unpin starts a fresh ordinary retention period")
        } else { check(false, "unpin starts a fresh ordinary retention period") }
        let marker = "private-history-payload-should-never-be-plaintext"
        _ = try store.insert(snapshot(marker), applicationName: "Fixture", applicationID: "test", now: now)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let exposed = files.contains { (try? Data(contentsOf: $0).range(of: Data(marker.utf8))) != nil }
        check(!exposed, "both searchable metadata and copyable payload are encrypted on disk")
        if failures > 0 { exit(1) }
    }
}
