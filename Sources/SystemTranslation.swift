import AppKit
import SwiftUI
import Translation
import OSLog

@MainActor
final class SystemTranslation {
    let view: NSView
    var onPreparationChanged: ((Bool) -> Void)?
    private let performUI: ([String], String?, TranslationTarget, Bool, @escaping () -> Void) async throws -> [String]
    private let stopUI: () -> Void
    private var directCancel: (() -> Void)?
    private var currentID: UUID?
    private var preparing = false
    private let logger = Logger(subsystem: "com.local.screenclip", category: "SystemTranslation")

    init() {
        if #available(macOS 15.0, *) {
            let bridge = SystemTranslationBridge()
            view = NSHostingView(rootView: SystemTranslationView(bridge: bridge))
            performUI = { text, source, target, needsPreparation, prepared in
                try await bridge.translate(text, source: source, to: target, needsPreparation: needsPreparation, prepared: prepared)
            }
            stopUI = { bridge.cancel() }
        } else {
            view = NSView()
            performUI = { _, _, _, _, _ in throw SystemTranslationProblem.unavailable }
            stopUI = {}
        }
    }

    func translate(_ text: String, to target: TranslationTarget) async throws -> String {
        try await translateBatch([text], to: target)[0]
    }

    func translateBatch(_ texts: [String], to target: TranslationTarget) async throws -> [String] {
        try Task.checkCancellation()
        guard !texts.isEmpty, texts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw TranslationFailure.noText }
        cancel()
        let id = UUID(); currentID = id
        defer {
            if currentID == id {
                directCancel = nil; setPreparing(false, id: id); currentID = nil
            }
        }
        do {
            return try await withTaskCancellationHandler(operation: {
                if #available(macOS 15.0, *) { return try await translateAvailable(texts, target: target, id: id) }
                throw SystemTranslationProblem.unavailable
            }, onCancel: { [weak self] in Task { @MainActor in self?.cancel(id: id) } })
        } catch is CancellationError { throw CancellationError() }
        catch let error as SystemTranslationProblem { throw error }
        catch {
            if Task.isCancelled { throw CancellationError() }
            let native = error as NSError
            logger.error("System translation failed: domain=\(native.domain, privacy: .public); code=\(native.code)")
            if #available(macOS 15.0, *) {
                if TranslationError.unableToIdentifyLanguage ~= error { throw SystemTranslationProblem.unidentified }
                if TranslationError.unsupportedSourceLanguage ~= error || TranslationError.unsupportedTargetLanguage ~= error || TranslationError.unsupportedLanguagePairing ~= error {
                    throw SystemTranslationProblem.unsupported
                }
            }
            throw SystemTranslationProblem.failed(native.code)
        }
    }

    @available(macOS 15.0, *)
    private func translateAvailable(_ texts: [String], target: TranslationTarget, id: UUID) async throws -> [String] {
        var values = Array(repeating: "", count: texts.count)
        // Group by identified source language. Already-translated labels need no model request.
        var groups: [(source: String?, indices: [Int])] = []
        let plans = SystemTranslationLanguage.plans(texts, target: target)
        for (index, text) in texts.enumerated() {
            let source: String?
            switch plans[index] {
            case .unchanged: values[index] = text; continue
            case .translate(let language): source = language
            case .automatic: source = nil
            }
            if let group = groups.firstIndex(where: { $0.source == source }) { groups[group].indices.append(index) }
            else { groups.append((source, [index])) }
        }
        for group in groups {
            try Task.checkCancellation()
            guard currentID == id else { throw CancellationError() }
            let input = group.indices.map { texts[$0] }
            var needsPreparation = true
            var translated: [String]?
            if let source = group.source {
                let language = Locale.Language(identifier: source)
                let status = await LanguageAvailability().status(from: language, to: Locale.Language(identifier: target.rawValue))
                try Task.checkCancellation()
                guard currentID == id else { throw CancellationError() }
                guard status != .unsupported else { throw SystemTranslationProblem.unsupported }
                needsPreparation = status != .installed
                if #available(macOS 26.0, *), status == .installed {
                    let session = TranslationSession(installedSource: language, target: Locale.Language(identifier: target.rawValue))
                    directCancel = { session.cancel() }
                    logger.notice("Using installed-language batch; blocks: \(input.count); source: \(source, privacy: .public)")
                    let requests = input.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
                    let responses = try await session.translations(from: requests)
                    translated = try TranslationBatchMapping.ordered(responses.map { ($0.clientIdentifier, $0.targetText) }, count: input.count)
                    directCancel = nil
                }
            }
            if translated == nil {
                setPreparing(needsPreparation, id: id)
                translated = try await performUI(input, group.source, target, needsPreparation) { [weak self] in
                    self?.setPreparing(false, id: id)
                }
            }
            try Task.checkCancellation()
            guard currentID == id, let translated, translated.count == group.indices.count else { throw CancellationError() }
            for (offset, index) in group.indices.enumerated() { values[index] = translated[offset] }
        }
        return values
    }

    private func setPreparing(_ value: Bool, id: UUID) {
        guard currentID == id, preparing != value else { return }
        preparing = value; onPreparationChanged?(value)
    }
    func cancel() {
        if let id = currentID { cancel(id: id) }
        else { stopUI() }
    }
    private func cancel(id: UUID) {
        guard currentID == id else { return }
        directCancel?(); directCancel = nil; stopUI()
        setPreparing(false, id: id); currentID = nil
    }
}

private enum SystemTranslationProblem: LocalizedError {
    case unavailable, unsupported, unidentified, failed(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "系统翻译需要 macOS 15 或以上，可在设置中更换服务。"
        case .unsupported: return "系统暂不支持这组语言，请更换目标语言或翻译服务。"
        case .unidentified: return "无法判断原文语言，请多框选一些文字后重试。"
        case .failed(let code): return "系统翻译未完成（\(code)），可重试或更换服务。"
        }
    }
}

@available(macOS 15.0, *)
@MainActor
private final class SystemTranslationBridge: ObservableObject {
    @Published var configuration: TranslationSession.Configuration?
    private struct Pending {
        let id: UUID
        let text: [String]
        let needsPreparation: Bool
        let prepared: () -> Void
        let continuation: CheckedContinuation<[String], Error>
    }
    private var pending: Pending?
    var requestID: UUID? { pending?.id }

    func translate(_ text: [String], source: String?, to target: TranslationTarget,
                   needsPreparation: Bool, prepared: @escaping () -> Void) async throws -> [String] {
        try Task.checkCancellation()
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                cancel()
                pending = Pending(id: id, text: text, needsPreparation: needsPreparation, prepared: prepared, continuation: continuation)
                let from = source.map { Locale.Language(identifier: $0) }
                if var next = configuration {
                    next.source = from; next.target = Locale.Language(identifier: target.rawValue)
                    next.invalidate(); configuration = next
                } else {
                    configuration = TranslationSession.Configuration(source: from, target: Locale.Language(identifier: target.rawValue))
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.cancel(id: id) } })
    }

    func perform(_ session: TranslationSession, requestID: UUID?) async {
        guard let request = pending, request.id == requestID else { return }
        do {
            if request.needsPreparation {
                // Keep the hosting view in the visible window so the system can ask to download languages.
                try await session.prepareTranslation()
                try Task.checkCancellation()
                guard pending?.id == request.id else { return }
                request.prepared()
            }
            let batch = request.text.enumerated().map { TranslationSession.Request(sourceText: $0.element, clientIdentifier: String($0.offset)) }
            let responses = try await session.translations(from: batch)
            let values = try TranslationBatchMapping.ordered(responses.map { ($0.clientIdentifier, $0.targetText) }, count: batch.count)
            complete(request.id, with: .success(values))
        } catch { complete(request.id, with: .failure(error)) }
    }

    func cancel() {
        guard let request = pending else { return }
        pending = nil; configuration = nil
        request.continuation.resume(throwing: CancellationError())
    }
    private func cancel(id: UUID) { if pending?.id == id { cancel() } }
    private func complete(_ id: UUID, with result: Result<[String], Error>) {
        guard let request = pending, request.id == id else { return }
        pending = nil; request.continuation.resume(with: result)
    }
}

@available(macOS 15.0, *)
private struct SystemTranslationView: View {
    @ObservedObject var bridge: SystemTranslationBridge
    var body: some View {
        let requestID = bridge.requestID
        Color.clear.frame(width: 1, height: 1)
            .translationTask(bridge.configuration) { session in await bridge.perform(session, requestID: requestID) }
            .accessibilityHidden(true)
    }
}
