import Foundation

struct ClipboardHistoryEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let fingerprint: String
    let text: String
    let hasImage: Bool
    let byteCount: Int
    let applicationName: String
    let applicationID: String
    var copiedAt: Date
    var pinned: Bool
    var title: String {
        let value = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (hasImage ? "图片" : "文件或富文本") : String(value.prefix(160))
    }
}

enum ClipboardHistoryFailure: LocalizedError {
    case unavailable, full, invalid, encryption
    var errorDescription: String? {
        switch self {
        case .unavailable: return "历史未能保存，请检查本机存储空间和权限。"
        case .full: return "历史空间已满，请清理内容或取消部分置顶。置顶项目不会自动删除。"
        case .invalid: return "这条历史无法读取，请删除后重新复制。"
        case .encryption: return "历史加密密钥暂不可用，请解锁钥匙串后重新打开助手。已有记录保持不变。"
        }
    }
}

/// Accessed on ClipboardHistory's serial worker queue; never by preview views directly.
final class ClipboardHistoryStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    let directory: URL
    private var savedEntries: [ClipboardHistoryEntry] = []
    private(set) var entries: [ClipboardHistoryEntry] {
        get { lock.withLock { savedEntries } }
        set { lock.withLock { savedEntries = newValue } }
    }
    private var countLimit = 5000, byteLimit = 1024 * 1024 * 1024, days = 30
    var maximumCount: Int { get { lock.withLock { countLimit } } set { lock.withLock { countLimit = newValue } } }
    var maximumBytes: Int { get { lock.withLock { byteLimit } } set { lock.withLock { byteLimit = newValue } } }
    var retentionDays: Int { get { lock.withLock { days } } set { lock.withLock { days = newValue } } }
    private let encryption: ClipboardHistoryEncryption
    private struct Manifest: Codable { let version: Int; let entries: [ClipboardHistoryEntry] }
    private var manifestURL: URL { directory.appendingPathComponent("history.enc") }
    private var legacyURL: URL { directory.appendingPathComponent("history.json") }

    init(directory: URL, encryptionKey: Data? = nil) throws {
        self.directory = directory
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        var folder = directory; try? folder.setResourceValues(resources)
        let key = try encryptionKey ?? ClipboardHistoryEncryption.keychainKey(createIfMissing: !files.fileExists(atPath: directory.appendingPathComponent("history.enc").path))
        encryption = try ClipboardHistoryEncryption(keyData: key)
        if files.fileExists(atPath: manifestURL.path) {
            let data = try boundedData(manifestURL, limit: 256 * 1024 * 1024)
            let saved = try JSONDecoder().decode(Manifest.self, from: encryption.open(data, context: "manifest-v2"))
            try validate(saved, version: 2)
            entries = saved.entries
            cleanupPayloads()
        } else if files.fileExists(atPath: legacyURL.path) {
            let data = try boundedData(legacyURL, limit: 64 * 1024 * 1024)
            let saved = try JSONDecoder().decode(Manifest.self, from: data)
            try validate(saved, version: 1)
            // Commit encrypted payloads before the manifest. A failed migration leaves every legacy byte intact.
            for entry in saved.entries {
                let old = directory.appendingPathComponent(entry.id.uuidString + ".plist")
                let snapshot = try decodeSnapshot(try boundedData(old, limit: ClipboardCapture.maximumItemBytes + 65536), entry: entry)
                try writePayload(snapshot, id: entry.id)
            }
            try save(saved.entries)
        }
    }
    private func validate(_ value: Manifest, version: Int) throws {
        guard value.version == version, value.entries.count <= 10_000,
              Set(value.entries.map(\.id)).count == value.entries.count,
              value.entries.allSatisfy({ $0.byteCount > 0 && $0.byteCount <= ClipboardCapture.maximumItemBytes })
        else { throw ClipboardHistoryFailure.invalid }
    }
    private func boundedData(_ url: URL, limit: Int) throws -> Data {
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? Int.max
        guard size <= limit else { throw ClipboardHistoryFailure.invalid }
        return try Data(contentsOf: url)
    }
    @discardableResult func insert(_ snapshot: ClipboardSnapshot, applicationName: String, applicationID: String, now: Date = Date()) throws -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard !snapshot.items.isEmpty, snapshot.byteCount > 0,
              snapshot.byteCount <= ClipboardCapture.maximumItemBytes else { throw ClipboardHistoryFailure.full }
        let fingerprint = snapshot.fingerprint
        if let index = entries.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var proposed = entries; let id = proposed[index].id; proposed[index].copiedAt = now
            try save(trim(proposed, now: now)); return id
        }
        var searchText = Data(snapshot.text.utf8.prefix(20_000))
        while String(data: searchText, encoding: .utf8) == nil { searchText.removeLast() }
        let entry = ClipboardHistoryEntry(id: UUID(), fingerprint: fingerprint,
            text: String(decoding: searchText, as: UTF8.self), hasImage: snapshot.imageData != nil,
            byteCount: snapshot.byteCount, applicationName: String(applicationName.prefix(120)),
            applicationID: applicationID, copiedAt: now, pinned: false)
        let proposed = trim(entries + [entry], now: now)
        guard proposed.contains(where: { $0.id == entry.id }) else { throw ClipboardHistoryFailure.full }
        try writePayload(snapshot, id: entry.id)
        do { try save(proposed) }
        catch { try? FileManager.default.removeItem(at: payloadURL(entry.id)); throw error }
        return entry.id
    }
    func read(_ id: UUID) throws -> ClipboardSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries.first(where: { $0.id == id }) else { throw ClipboardHistoryFailure.invalid }
        let data = try boundedData(payloadURL(id), limit: ClipboardCapture.maximumItemBytes + 65536)
        return try decodeSnapshot(encryption.open(data, context: id.uuidString), entry: entry)
    }
    private func decodeSnapshot(_ data: Data, entry: ClipboardHistoryEntry) throws -> ClipboardSnapshot {
        let snapshot = try PropertyListDecoder().decode(ClipboardSnapshot.self, from: data)
        guard snapshot.byteCount == entry.byteCount, snapshot.fingerprint == entry.fingerprint else { throw ClipboardHistoryFailure.invalid }
        return snapshot
    }
    private func writePayload(_ snapshot: ClipboardSnapshot, id: UUID) throws {
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encryption.seal(encoder.encode(snapshot), context: id.uuidString)
        try writePrivate(data, to: payloadURL(id))
    }
    func setPinned(_ id: UUID, _ value: Bool, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        var proposed = entries
        guard let index = proposed.firstIndex(where: { $0.id == id }), proposed[index].pinned != value else { return }
        proposed[index].pinned = value
        if !value { proposed[index].copiedAt = now }
        try save(proposed)
    }
    func remove(_ id: UUID) throws { try lock.withLock { try save(entries.filter { $0.id != id }) } }
    func clear(includingPinned: Bool = false) throws { try lock.withLock { try save(includingPinned ? [] : entries.filter(\.pinned)) } }
    func prune(now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let proposed = trim(entries, now: now)
        if proposed != entries { try save(proposed) }
    }
    private func payloadURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".clip") }
    private func trim(_ values: [ClipboardHistoryEntry], now: Date) -> [ClipboardHistoryEntry] {
        let threshold = now.addingTimeInterval(-Double(max(1, retentionDays)) * 86400)
        var result = values.filter { $0.pinned || $0.copiedAt >= threshold }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.copiedAt > $1.copiedAt }
        var bytes = result.reduce(0) { $0 + $1.byteCount }
        while result.count > max(1, min(10_000, maximumCount)) || bytes > maximumBytes {
            guard let index = result.lastIndex(where: { !$0.pinned }) else { break }
            bytes -= result[index].byteCount; result.remove(at: index)
        }
        return result
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func save(_ proposed: [ClipboardHistoryEntry]) throws {
        let data = try encryption.seal(JSONEncoder().encode(Manifest(version: 2, entries: proposed)), context: "manifest-v2")
        try writePrivate(data, to: manifestURL)
        entries = proposed; cleanupPayloads()
    }
    private func cleanupPayloads() {
        let retained = Set(entries.map { $0.id.uuidString + ".clip" })
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for url in files {
            let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            if url.lastPathComponent == "history.json" || (uuid != nil && (url.pathExtension == "plist" || url.pathExtension == "clip") && !retained.contains(url.lastPathComponent)) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
    func matching(_ query: String) -> [ClipboardHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.filter { query.isEmpty || $0.text.localizedStandardContains(query) || $0.applicationName.localizedStandardContains(query) }
            .sorted { $0.pinned != $1.pinned ? $0.pinned : $0.copiedAt > $1.copiedAt }
    }
}
