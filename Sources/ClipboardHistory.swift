import AppKit
import ImageIO
import OSLog

enum ClipboardPrimaryAction: String, Codable { case paste, copy }

struct ClipboardHistorySettings: Codable, Equatable {
    var schemaVersion = 2
    var isRecording = false
    var retentionDays = 30
    var maximumCount = 5000
    var maximumBytes = 1024 * 1024 * 1024
    var primaryAction = ClipboardPrimaryAction.paste
    var pasteAsPlainText = false
    var excludedApplications: [String: String] = [
        "com.1password.1password": "1Password", "com.agilebits.onepassword7": "1Password",
        "com.bitwarden.desktop": "Bitwarden", "org.keepassxc.keepassxc": "KeePassXC",
        "com.apple.keychainaccess": "钥匙串访问"
    ]
    init() {}
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, isRecording, retentionDays, maximumCount, maximumBytes, primaryAction, pasteAsPlainText, excludedApplications
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let oldVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        isRecording = try values.decodeIfPresent(Bool.self, forKey: .isRecording) ?? false
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30
        maximumCount = try values.decodeIfPresent(Int.self, forKey: .maximumCount) ?? 5000
        maximumBytes = try values.decodeIfPresent(Int.self, forKey: .maximumBytes) ?? 1024 * 1024 * 1024
        primaryAction = (try? values.decode(ClipboardPrimaryAction.self, forKey: .primaryAction)) ?? .paste
        pasteAsPlainText = try values.decodeIfPresent(Bool.self, forKey: .pasteAsPlainText) ?? false
        excludedApplications = try values.decodeIfPresent([String: String].self, forKey: .excludedApplications) ?? excludedApplications
        if oldVersion == 1 {
            if retentionDays == 7 { retentionDays = 30 }
            if maximumCount == 200 { maximumCount = 5000 }
        }
    }
}

struct ClipboardHistoryPreview {
    let text: String
    let image: CGImage?
}

@MainActor
final class ClipboardHistory {
    private static let settingsKey = "clipboardHistory.settings.v1"
    private let board: NSPasteboard
    private let defaults: UserDefaults
    private let source: () -> (name: String, id: String)
    private let directory: URL
    private let encryptionKey: Data?
    private let worker = DispatchQueue(label: "com.local.screenclip.history-storage", qos: .userInitiated)
    private var changeCount: Int
    private var timer: Timer?
    private var lastPrune = Date()
    private var store: ClipboardHistoryStore?
    private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var settings = ClipboardHistorySettings()
    private(set) var errorMessage: String?
    private(set) var pendingOperations = 0
    var onChange: (() -> Void)?

    init(board: NSPasteboard = .general, defaults: UserDefaults = .standard, directory: URL? = nil,
         encryptionKey: Data? = nil, source: @escaping () -> (name: String, id: String) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.localizedName ?? "未知应用", app?.bundleIdentifier ?? "")
         }) {
        self.board = board; self.defaults = defaults; self.source = source; self.encryptionKey = encryptionKey
        changeCount = board.changeCount
        if let data = defaults.data(forKey: Self.settingsKey),
           let value = try? JSONDecoder().decode(ClipboardHistorySettings.self, from: data) { settings = value }
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.local.screenclip/ClipboardHistory", isDirectory: true)
        do {
            let store = try ClipboardHistoryStore(directory: self.directory, encryptionKey: encryptionKey)
            self.store = store; configure(store, settings: settings)
            entries = store.matching("")
            Logger(subsystem: "com.local.screenclip", category: "Clipboard").notice("Encrypted history ready")
            // The initial data is immediately searchable; expiry and writes run off the UI thread.
            enqueue { try $0.prune() }
        } catch {
            errorMessage = error.localizedDescription; settings.isRecording = false
            Logger(subsystem: "com.local.screenclip", category: "Clipboard").error("Encrypted history unavailable; error code: \((error as NSError).code)")
        }
    }
    func matching(_ query: String) -> [ClipboardHistoryEntry] {
        entries.filter { query.isEmpty || $0.text.localizedStandardContains(query) || $0.applicationName.localizedStandardContains(query) }
    }
    func start() {
        guard timer == nil else { return }
        let next = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(next, forMode: .common); timer = next
    }
    func stop() { timer?.invalidate(); timer = nil }
    func poll() {
        if Date().timeIntervalSince(lastPrune) >= 60 {
            lastPrune = Date(); enqueue { try $0.prune() }
        }
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount
        guard settings.isRecording, store != nil else { return }
        let app = source()
        guard !settings.excludedApplications.keys.contains(where: { $0.caseInsensitiveCompare(app.id) == .orderedSame }),
              let snapshot = ClipboardCapture.read(board) else { return }
        enqueue { _ = try $0.insert(snapshot, applicationName: app.name, applicationID: app.id) }
    }
    func updateSettings(_ value: ClipboardHistorySettings) {
        let wasRecording = settings.isRecording
        settings = value; settings.schemaVersion = 2
        settings.retentionDays = max(1, min(90, settings.retentionDays))
        settings.maximumCount = max(1, min(10_000, settings.maximumCount))
        settings.maximumBytes = max(64 * 1024 * 1024, min(2 * 1024 * 1024 * 1024, settings.maximumBytes))
        if store == nil { settings.isRecording = false }
        if wasRecording != settings.isRecording { changeCount = board.changeCount }
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        let updated = settings
        enqueue { store in self.configure(store, settings: updated); try store.prune() }
        onChange?()
    }
    func setRecording(_ value: Bool) { var updated = settings; updated.isRecording = value; updateSettings(updated) }

    /// The original item is read on the storage queue. Only the native pasteboard write runs on the main thread.
    func copy(_ id: UUID, plainText: Bool = false, completion: @escaping (Bool) -> Void) {
        guard let store else { completion(false); return }
        worker.async { [weak self] in
            let result = Result { try store.read(id) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion(false); return }
                switch result {
                case .success(let snapshot):
                    let output: ClipboardSnapshot
                    if plainText && !snapshot.text.isEmpty {
                        output = ClipboardSnapshot(items: [[.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(snapshot.text.utf8))]])
                    } else { output = snapshot }
                    guard ClipboardCapture.write(output, to: self.board) else {
                        self.errorMessage = "复制失败，请重新复制原内容。"; self.onChange?(); completion(false); return
                    }
                    self.changeCount = self.board.changeCount
                    self.enqueue { _ = try $0.insert(snapshot, applicationName: "", applicationID: "") }
                    completion(true)
                case .failure:
                    self.errorMessage = "这条历史未能复制，请重试或重新复制原内容。"; self.onChange?(); completion(false)
                }
            }
        }
    }
    func loadPreview(_ id: UUID, maximumPixelSize: Int = 1200, completion: @escaping (ClipboardHistoryPreview?) -> Void) {
        guard let store else { completion(nil); return }
        worker.async {
            let result: ClipboardHistoryPreview? = autoreleasepool {
                guard let snapshot = try? store.read(id) else { return nil }
                var image: CGImage?
                if let data = snapshot.imageData, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
                    image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }
                let text = snapshot.text
                return ClipboardHistoryPreview(text: String(text.prefix(100_000)) + (text.count > 100_000 ? "\n\n预览已截短，粘贴保留完整内容。" : ""), image: image)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func setPinned(_ id: UUID, _ value: Bool) { enqueue { try $0.setPinned(id, value) } }
    func remove(_ id: UUID) { enqueue { try $0.remove(id) } }
    func clear(includingPinned: Bool = false) {
        guard store != nil else {
            guard includingPinned else { errorMessage = "历史无法载入，未删除任何记录。"; onChange?(); return }
            let directory = self.directory, key = encryptionKey
            worker.async { [weak self] in
                let result = Result { () -> ClipboardHistoryStore in
                    let actualKey = try key ?? ClipboardHistoryEncryption.keychainKey(createIfMissing: true)
                    for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                        let own = ["history.enc", "history.json"].contains(url.lastPathComponent)
                            || (["plist", "clip"].contains(url.pathExtension) && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil)
                        if own { try FileManager.default.removeItem(at: url) }
                    }
                    return try ClipboardHistoryStore(directory: directory, encryptionKey: actualKey)
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch result {
                    case .success(let store): self.store = store; self.entries = []; self.errorMessage = nil
                        let configuration = self.settings
                        self.enqueue { self.configure($0, settings: configuration) }
                    case .failure(let error): self.errorMessage = error.localizedDescription
                    }
                    self.onChange?()
                }
            }
            return
        }
        enqueue { try $0.clear(includingPinned: includingPinned) }
        changeCount = board.changeCount
    }
    /// Used by deterministic tests and orderly app shutdown; does not capture or paste anything.
    func flush() async {
        repeat {
            await withCheckedContinuation { continuation in
                worker.async { DispatchQueue.main.async { continuation.resume() } }
            }
        } while pendingOperations > 0
    }
    nonisolated private func configure(_ store: ClipboardHistoryStore, settings: ClipboardHistorySettings) {
        store.maximumCount = max(1, min(10_000, settings.maximumCount))
        store.maximumBytes = settings.maximumBytes; store.retentionDays = max(1, min(90, settings.retentionDays))
    }
    private func enqueue(_ operation: @escaping (ClipboardHistoryStore) throws -> Void) {
        guard let store else { onChange?(); return }
        pendingOperations += 1
        worker.async { [weak self] in
            let result = Result { try operation(store); return store.matching("") }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingOperations -= 1
                switch result {
                case .success(let entries): self.entries = entries; self.errorMessage = nil
                case .failure(let error): self.errorMessage = error.localizedDescription
                }
                self.onChange?()
            }
        }
    }
}
