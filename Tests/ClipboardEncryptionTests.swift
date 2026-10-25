import Foundation

@main struct ClipboardEncryptionTests {
    private struct Legacy: Encodable { let version = 1; let entries: [ClipboardHistoryEntry] }
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-encryption-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var failures = 0
        func check(_ condition: Bool, _ name: String) { print("\(condition ? "PASS" : "FAIL") \(name)"); if !condition { failures += 1 } }
        let key = Data(repeating: 0x42, count: 32)
        let snapshot = ClipboardSnapshot(items: [[.init(type: "public.utf8-plain-text", data: Data("private migration fixture 中文".utf8)),
            .init(type: "public.rtf", data: Data("{\\rtf1 Original rich text}".utf8))]])
        let entry = ClipboardHistoryEntry(id: UUID(), fingerprint: snapshot.fingerprint, text: snapshot.text, hasImage: false,
            byteCount: snapshot.byteCount, applicationName: "Fixture", applicationID: "test.fixture",
            copiedAt: Date().addingTimeInterval(-120 * 86400), pinned: true)
        let manifest = try JSONEncoder().encode(Legacy(entries: [entry]))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let payload = try encoder.encode(snapshot)
        let legacyURL = folder.appendingPathComponent("history.json"), legacyPayload = folder.appendingPathComponent(entry.id.uuidString + ".plist")
        try manifest.write(to: legacyURL); try payload.write(to: legacyPayload)
        do { _ = try ClipboardHistoryStore(directory: folder, encryptionKey: Data(count: 16)); check(false, "an unusable key stops migration") }
        catch { check(true, "an unusable key stops migration") }
        check(try Data(contentsOf: legacyURL) == manifest && Data(contentsOf: legacyPayload) == payload,
              "failed migration leaves the original manifest and payload byte-for-byte intact")
        let store = try ClipboardHistoryStore(directory: folder, encryptionKey: key)
        let migratedSnapshot = try store.read(entry.id)
        check(store.entries == [entry] && migratedSnapshot == snapshot, "migration preserves identity, original formats, source, date and pin")
        check(!FileManager.default.fileExists(atPath: legacyURL.path) && !FileManager.default.fileExists(atPath: legacyPayload.path),
              "legacy plaintext is removed only after the encrypted manifest commits")
        let reloaded = try ClipboardHistoryStore(directory: folder, encryptionKey: key)
        let reloadedSnapshot = try reloaded.read(entry.id)
        check(reloaded.entries == [entry] && reloadedSnapshot == snapshot, "encrypted history survives a fresh process instance")
        let manifestURL = folder.appendingPathComponent("history.enc")
        let encryptedManifest = try Data(contentsOf: manifestURL)
        do { _ = try ClipboardHistoryStore(directory: folder, encryptionKey: Data(repeating: 0x43, count: 32)); check(false, "a wrong key cannot load or reset history") }
        catch { check(true, "a wrong key cannot load or reset history") }
        check(try Data(contentsOf: manifestURL) == encryptedManifest, "a wrong-key failure never overwrites the valid history")
        let payloadURL = folder.appendingPathComponent(entry.id.uuidString + ".clip")
        var damaged = try Data(contentsOf: payloadURL); damaged[damaged.count - 1] ^= 1; try damaged.write(to: payloadURL)
        do { _ = try reloaded.read(entry.id); check(false, "modified ciphertext is rejected instead of copied") }
        catch { check(true, "modified ciphertext is rejected instead of copied") }
        let cipher = try ClipboardHistoryEncryption(keyData: key)
        let sealed = try cipher.seal(Data("fixture".utf8), context: "first-item")
        do { _ = try cipher.open(sealed, context: "second-item"); check(false, "ciphertext cannot be substituted between records") }
        catch { check(true, "ciphertext cannot be substituted between records") }
        try reloaded.clear(includingPinned: true)
        let empty = try ClipboardHistoryStore(directory: folder, encryptionKey: key)
        check(empty.entries.isEmpty && !FileManager.default.fileExists(atPath: payloadURL.path), "explicit delete-all removes pinned payloads and persists an empty encrypted history")
        if failures > 0 { exit(1) }
        print("Encrypted migration, integrity and recovery checks passed with synthetic data; Keychain untouched")
    }
}
