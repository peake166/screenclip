import Foundation
import OSLog

@MainActor
final class TranslationWorkflow {
    enum Phase: Equatable {
        case idle, recognizing, preparingLanguage, translating(Int, Int), finished, failed(String)
        var isBusy: Bool {
            switch self { case .recognizing, .preparingLanguage, .translating: return true; default: return false }
        }
    }
    private(set) var phase: Phase = .idle
    private(set) var original = ""
    private(set) var translated = ""
    private(set) var settings = TranslationSettings()
    private(set) var document: OCRDocument?
    var translatedBlocks: [Int: String] {
        var values: [Int: String] = [:]
        for block in document?.blocks ?? [] {
            let indices = blockIDs.indices.filter { blockIDs[$0] == block.id }
            if !indices.isEmpty, indices.allSatisfy({ $0 < results.count && results[$0] != nil }) {
                values[block.id] = indices.compactMap { results[$0] }.joined(separator: "\n")
            }
        }
        return values
    }
    var onChange: (() -> Void)?
    private let recognize: (Raster) async throws -> String
    private let translate: (String, TranslationSettings) async throws -> String
    private var recognizeLayout: ((Raster) async throws -> OCRDocument)?
    private var translateBatch: (([String], TranslationSettings) async throws -> [String])?
    private var blockIDs: [Int] = []
    private var image: Raster?
    private var pieces: [String] = []
    private var results: [String?] = []
    private var task: Task<Void, Never>?
    private struct CloudRequest {
        let generation: UUID
        let task: Task<Void, Never>
    }
    // Keep cancelled requests here until the provider actually returns. A provider
    // ignoring cancellation must not make a replacement run exceed two requests.
    private var cloudRequests: [UUID: CloudRequest] = [:]
    private var cloudGeneration: UUID?
    private var pendingCloudPieces: [Int] = []
    private var cloudFailure: String?
    private var cloudConcurrency = 2
    private var deadlineTask: Task<Void, Never>?
    private var deadlineID = UUID()
    private var stageStarted = Date()
    private let recognitionTimeout: TimeInterval
    private let translationTimeout: TimeInterval
    private let logger = Logger(subsystem: "com.local.screenclip", category: "Translation")
    private var generation = UUID()
    init(recognitionTimeout: TimeInterval = 120, translationTimeout: TimeInterval = 75,
         recognize: @escaping (Raster) async throws -> String, translate: @escaping (String, TranslationSettings) async throws -> String) {
        self.recognitionTimeout = recognitionTimeout; self.translationTimeout = translationTimeout
        self.recognize = recognize; self.translate = translate
    }
    convenience init(recognizeLayout: @escaping (Raster) async throws -> OCRDocument,
                     translate: @escaping (String, TranslationSettings) async throws -> String,
                     translateBatch: (([String], TranslationSettings) async throws -> [String])? = nil) {
        self.init(recognize: { try await recognizeLayout($0).text }, translate: translate)
        self.recognizeLayout = recognizeLayout; self.translateBatch = translateBatch
    }
    func begin(_ image: Raster, settings: TranslationSettings) {
        cancel()
        cloudConcurrency = 2
        self.image = image; self.settings = settings
        original = ""; translated = ""; pieces = []; results = []; document = nil; blockIDs = []
        run()
    }
    func retry() {
        guard case .failed = phase else { return }
        run()
    }
    func retranslate(settings: TranslationSettings) {
        guard !original.isEmpty else { retry(); return }
        cancel()
        self.settings = settings; results = Array(repeating: nil, count: pieces.count); translated = ""
        run()
    }
    func clear() {
        cancel(); original = ""; translated = ""; pieces = []; results = []; document = nil; blockIDs = []
        phase = .idle; onChange?()
    }
    func cancel() {
        finishStage()
        generation = UUID(); task?.cancel(); task = nil
        cancelCloudRequests()
        image = nil
        if phase.isBusy { phase = .idle; onChange?() }
    }
    func expireCurrentStage() {
        guard phase.isBusy else { return }
        let message: String
        switch phase {
        case .recognizing: message = "识别等待超时，请重新框选。"
        case .preparingLanguage: message = "语言准备超时，请完成语言下载后重试。"
        default: message = "翻译等待超时，可以重试或更换服务。"
        }
        logger.error("Stage timeout: \(self.stageName, privacy: .public)")
        finishStage()
        generation = UUID(); task?.cancel(); task = nil
        cancelCloudRequests()
        phase = .failed(message); onChange?()
    }
    func preparingLanguage(_ preparing: Bool) {
        guard phase.isBusy, !original.isEmpty else { return }
        finishStage()
        phase = preparing ? .preparingLanguage : .translating(completedCount + 1, pieces.count)
        armDeadline(preparing ? 180 : translationTimeout)
        onChange?()
    }
    private var stageName: String {
        switch phase { case .recognizing: return "ocr"; case .preparingLanguage: return "language-preparation"; default: return "translation" }
    }
    private func finishStage() {
        if deadlineTask != nil {
            logger.notice("Stage ended: \(self.stageName, privacy: .public); milliseconds: \(Int(Date().timeIntervalSince(self.stageStarted) * 1000))")
        }
        deadlineID = UUID(); deadlineTask?.cancel(); deadlineTask = nil
    }
    private func armDeadline(_ seconds: TimeInterval) {
        let id = UUID(); deadlineID = id; stageStarted = Date()
        logger.notice("Stage started: \(self.stageName, privacy: .public); provider: \(self.settings.provider.rawValue, privacy: .public)")
        deadlineTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000)) }
            catch { return }
            guard let self, self.deadlineID == id else { return }
            self.expireCurrentStage()
        }
    }
    private func run() {
        let token = UUID(); generation = token
        phase = pieces.isEmpty ? .recognizing : .translating(completedCount + 1, pieces.count)
        armDeadline(pieces.isEmpty ? recognitionTimeout : translationTimeout)
        onChange?()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if self.pieces.isEmpty {
                    guard let image = self.image else { throw TranslationFailure.noText }
                    let layout = try await self.recognizeLayout?(image)
                    let text: String
                    if let layout { text = layout.text } else { text = try await self.recognize(image) }
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.finishStage()
                    self.original = text
                    // Validate the complete screenshot before making any provider request.
                    _ = try TranslationText.chunks(text)
                    self.document = layout
                    if let layout {
                        for block in layout.blocks {
                            let chunks = try TranslationText.chunks(block.text)
                            self.pieces += chunks
                            self.blockIDs += Array(repeating: block.id, count: chunks.count)
                        }
                    } else { self.pieces = try TranslationText.chunks(text) }
                    self.results = Array(repeating: nil, count: self.pieces.count)
                    self.image = nil
                }
                if self.settings.provider != .system {
                    self.finishStage()
                    self.cloudGeneration = token
                    self.cloudFailure = nil
                    self.pendingCloudPieces = self.pieces.indices.filter { self.results[$0] == nil }
                    self.phase = .translating(self.completedCount + 1, self.pieces.count)
                    self.armDeadline(self.translationTimeout); self.onChange?()
                    self.task = nil
                    self.scheduleCloudRequests()
                    return
                }
                while let index = self.results.firstIndex(where: { $0 == nil }) {
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.finishStage()
                    self.phase = .translating(index + 1, self.pieces.count)
                    self.armDeadline(self.translationTimeout); self.onChange?()
                    let values: [String]
                    if self.settings.provider == .system, let batch = self.translateBatch {
                        let end = min(index + 8, self.pieces.count)
                        values = try await batch(Array(self.pieces[index..<end]), self.settings)
                        guard values.count == end - index else { throw TranslationFailure.emptyResponse }
                    } else { values = [try await self.translate(self.pieces[index], self.settings)] }
                    guard self.generation == token, !Task.isCancelled else { return }
                    self.finishStage()
                    guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TranslationFailure.emptyResponse }
                    for offset in values.indices { self.results[index + offset] = values[offset] }
                    self.refreshTranslatedText()
                    self.onChange?()
                }
                self.phase = .finished; self.task = nil; self.onChange?()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.finishStage()
                let nativeError = error as NSError
                self.logger.error("Translation failed: domain=\(nativeError.domain, privacy: .public); code=\(nativeError.code)")
                self.phase = .failed(error.localizedDescription); self.task = nil; self.onChange?()
            }
        }
    }
    private var completedCount: Int { results.compactMap { $0 }.count }
    private func refreshTranslatedText() { translated = results.compactMap { $0 }.joined(separator: "\n\n") }
    private func cancelCloudRequests() {
        cloudGeneration = nil; pendingCloudPieces = []; cloudFailure = nil
        for request in cloudRequests.values { request.task.cancel() }
    }
    private func scheduleCloudRequests() {
        guard let token = cloudGeneration, generation == token, phase.isBusy else { return }
        while cloudRequests.count < cloudConcurrency, cloudFailure == nil, !pendingCloudPieces.isEmpty {
            let index = pendingCloudPieces.removeFirst(), id = UUID()
            let text = pieces[index], configuration = settings, operation = translate
            let request = Task { [weak self] in
                let result: Result<String, Error>
                do {
                    let value = try await operation(text, configuration)
                    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationFailure.emptyResponse }
                    result = .success(value)
                } catch { result = .failure(error) }
                self?.completeCloudRequest(id: id, index: index, token: token, result: result)
            }
            cloudRequests[id] = CloudRequest(generation: token, task: request)
        }
        guard !cloudRequests.values.contains(where: { $0.generation == token }) else { return }
        if let cloudFailure {
            finishStage(); phase = .failed(cloudFailure); cloudGeneration = nil; onChange?()
        } else if pendingCloudPieces.isEmpty {
            finishStage(); phase = .finished; cloudGeneration = nil; onChange?()
        }
    }
    private func completeCloudRequest(id: UUID, index: Int, token: UUID, result: Result<String, Error>) {
        cloudRequests[id] = nil
        if generation == token, cloudGeneration == token, phase.isBusy {
            finishStage()
            switch result {
            case .success(let value):
                results[index] = value; refreshTranslatedText()
            case .failure(let error):
                let nativeError = error as NSError
                logger.error("Translation failed: domain=\(nativeError.domain, privacy: .public); code=\(nativeError.code)")
                if let failure = error as? TranslationFailure, case .rejected(429) = failure { cloudConcurrency = 1 }
                if cloudFailure == nil { cloudFailure = error.localizedDescription }
            }
            phase = .translating(min(completedCount + 1, pieces.count), pieces.count)
            armDeadline(translationTimeout); onChange?()
        }
        // A stale completion only frees its occupied slot. It cannot write text,
        // replace the current error, or restart work from the cancelled run.
        scheduleCloudRequests()
    }
}
