import Foundation

struct TranslationBenchmarkCandidate: Hashable {
    let provider: TranslationProvider
    let model: String
}

struct TranslationBenchmarkResult: Equatable {
    let seconds: TimeInterval
    let charactersPerSecond: Double
    let translation: String
}

enum TranslationBenchmarkState: Equatable {
    case ready, running, success(TranslationBenchmarkResult), failed(String), stopped
}

struct TranslationBenchmarkEntry: Equatable {
    let candidate: TranslationBenchmarkCandidate
    var state: TranslationBenchmarkState = .ready
}

@MainActor
final class TranslationBenchmark {
    typealias Translator = (String, TranslationSettings, String) async throws -> String
    nonisolated static let timeoutSeconds: TimeInterval = 12
    let settings: TranslationSettings
    let sample: String
    private let keys: [TranslationProvider: String]
    private let translate: Translator
    private let timeout: TimeInterval
    private let spacing: TimeInterval
    private let now: () -> TimeInterval
    private var task: Task<Void, Never>?
    private var runID = UUID()
    private(set) var entries: [TranslationBenchmarkEntry]
    private(set) var isRunning = false
    private(set) var isStopping = false
    var onChange: (() -> Void)?

    init(settings: TranslationSettings, keys: [TranslationProvider: String], translator: Translator? = nil,
         timeout: TimeInterval = timeoutSeconds, spacing: TimeInterval = 0.75,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.settings = settings; self.keys = keys; self.timeout = timeout; self.spacing = spacing; self.now = now
        sample = Self.sample(for: settings.target)
        entries = Self.candidates(settings: settings, keys: keys).map { TranslationBenchmarkEntry(candidate: $0) }
        let cloud = CloudTranslation()
        translate = translator ?? { text, config, key in try await cloud.translate(text, settings: config, key: key) }
    }

    static func candidates(settings: TranslationSettings, keys: [TranslationProvider: String]) -> [TranslationBenchmarkCandidate] {
        var result: [TranslationBenchmarkCandidate] = []
        for provider in TranslationProvider.allCases where provider != .system {
            guard let key = keys[provider], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var models = provider.suggestedModels
            let custom = settings.model(for: provider)
            if TranslationSettingsStore.validModel(custom), !models.contains(custom) { models.append(custom) }
            result += models.map { TranslationBenchmarkCandidate(provider: provider, model: $0) }
        }
        return result
    }

    static func sample(for target: TranslationTarget) -> String {
        target == .english
            ? "会议将于周五上午十点开始。请查看更新后的计划，并在明天之前提出反馈。\n\n新版本更容易使用，并会保留你原有的设置。"
            : "The meeting will start at 10 a.m. on Friday. Please review the updated plan and share your feedback by tomorrow.\n\nThe new version is easier to use and keeps your existing settings."
    }

    var rankedEntries: [TranslationBenchmarkEntry] {
        entries.enumerated().sorted { left, right in
            switch (left.element.state, right.element.state) {
            case (.success(let a), .success(let b)): return a.seconds == b.seconds ? left.offset < right.offset : a.seconds < b.seconds
            case (.success, _): return true
            case (_, .success): return false
            default: return left.offset < right.offset
            }
        }.map(\.element)
    }
    var fastest: TranslationBenchmarkCandidate? {
        guard let first = rankedEntries.first, case .success = first.state else { return nil }
        return first.candidate
    }
    var completedCount: Int {
        entries.filter { if case .success = $0.state { return true }; if case .failed = $0.state { return true }; return false }.count
    }

    @discardableResult func start() -> Bool {
        guard task == nil, !entries.isEmpty else { return false }
        isRunning = true
        entries = entries.map { TranslationBenchmarkEntry(candidate: $0.candidate) }
        onChange?()
        let id = UUID(); runID = id
        task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id)
            if self.runID == id {
                self.task = nil; self.isRunning = false; self.isStopping = false; self.onChange?()
            }
        }
        return true
    }

    func stop() {
        guard task != nil, !isStopping else { return }
        isRunning = false; isStopping = true; task?.cancel()
        markStopped(); onChange?()
    }
    func waitUntilFinished() async { await task?.value }
    private func markStopped() {
        for index in entries.indices {
            if entries[index].state == .ready || entries[index].state == .running { entries[index].state = .stopped }
        }
    }

    private func run(id: UUID) async {
        for index in entries.indices {
            do {
                if index > 0, spacing > 0 { try await Task.sleep(nanoseconds: UInt64(spacing * 1_000_000_000)) }
                try Task.checkCancellation()
            } catch { markStopped(); return }
            guard runID == id else { return }
            let candidate = entries[index].candidate
            var configuration = settings
            configuration.provider = candidate.provider
            configuration.setModel(candidate.model, for: candidate.provider)
            entries[index].state = .running; onChange?()
            let started = now()
            do {
                let translated = try await Self.translateWithinDeadline(sample, settings: configuration,
                    key: keys[candidate.provider] ?? "", translator: translate, timeout: timeout)
                try Task.checkCancellation()
                guard runID == id else { return }
                let value = translated.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { throw TranslationFailure.emptyResponse }
                guard value.split(whereSeparator: \.isWhitespace) != sample.split(whereSeparator: \.isWhitespace) else {
                    throw BenchmarkProblem.unchanged
                }
                let seconds = max(0.001, now() - started)
                entries[index].state = .success(TranslationBenchmarkResult(seconds: seconds,
                    charactersPerSecond: Double(sample.count) / seconds, translation: value))
            } catch is CancellationError { markStopped(); return }
            catch {
                guard runID == id, !Task.isCancelled else { markStopped(); return }
                entries[index].state = .failed(safeMessage(for: error))
            }
            onChange?()
        }
    }

    private enum BenchmarkProblem: Error { case timedOut, unchanged }
    private func safeMessage(for error: Error) -> String {
        switch error {
        case BenchmarkProblem.timedOut: return "超时（\(Int(timeout.rounded(.up))) 秒）"
        case BenchmarkProblem.unchanged: return "返回了原文，请更换模型。"
        case let error as TranslationFailure: return error.localizedDescription
        default: return TranslationFailure.network.localizedDescription
        }
    }

    private static func translateWithinDeadline(_ text: String, settings: TranslationSettings, key: String,
                                                translator: @escaping Translator, timeout: TimeInterval) async throws -> String {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await translator(text, settings, key) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BenchmarkProblem.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}
