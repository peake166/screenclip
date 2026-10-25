import Foundation

private final class BenchmarkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 100
    func read() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

private actor BenchmarkFixture {
    struct Call { let text: String; let settings: TranslationSettings; let key: String }
    var calls: [Call] = []
    var active = 0, maximumActive = 0, cancellations = 0
    let clock = BenchmarkClock()
    func perform(_ text: String, _ config: TranslationSettings, _ key: String) async throws -> String {
        calls.append(Call(text: text, settings: config, key: key))
        active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        let model = config.model(for: config.provider)
        if model == "fixture-timeout" {
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { cancellations += 1; throw error }
        }
        clock.advance(model.contains("Hunyuan") ? 0.5 : 2)
        if model == "fixture-echo" { return text.replacingOccurrences(of: "\n", with: " ") }
        if model == "fixture-secret-error" { throw NSError(domain: "fixture-secret-key", code: 1) }
        if config.provider == .glm { throw TranslationFailure.rejected(429) }
        return "会议将于周五上午十点开始。请查看更新后的计划，并在明天之前提出反馈。\n\n新版本更容易使用，并会保留你原有的设置。"
    }
}

@main struct TranslationBenchmarkTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ name: String) { print("\(value ? "PASS" : "FAIL") \(name)"); if !value { failures += 1 } }
        var settings = TranslationSettings(); settings.siliconFlowModel = "fixture-custom"
        let keys: [TranslationProvider: String] = [.siliconFlow: "fixture-silicon", .glm: "fixture-glm"]
        let plan = TranslationBenchmark.candidates(settings: settings, keys: keys)
        check(plan.count == 7 && Set(plan).count == 7 && plan.contains(.init(provider: .siliconFlow, model: "fixture-custom")),
              "the plan includes every integrated cloud model and the configured custom model exactly once")
        check(TranslationBenchmark.candidates(settings: settings, keys: [.glm: "fixture-glm"]).allSatisfy { $0.provider == .glm }
              && TranslationBenchmark.candidates(settings: settings, keys: [.siliconFlow: "  "]).isEmpty,
              "providers without a usable key send no tests")
        check(TranslationBenchmark.sample(for: .english).contains("会议") && TranslationBenchmark.sample(for: .japanese).hasPrefix("The meeting"),
              "all compared models receive the same source language appropriate for the target")
        let fixture = BenchmarkFixture()
        let benchmark = TranslationBenchmark(settings: settings, keys: keys,
            translator: { try await fixture.perform($0, $1, $2) }, spacing: 0, now: { fixture.clock.read() })
        check(await fixture.calls.isEmpty, "constructing a benchmark sends no requests")
        var progress: [Int] = []
        benchmark.onChange = { progress.append(benchmark.completedCount) }
        check(benchmark.start() && !benchmark.start(), "a second start cannot create duplicate requests")
        await benchmark.waitUntilFinished()
        let calls = await fixture.calls
        let maximumActive = await fixture.maximumActive
        check(calls.count == plan.count && maximumActive == 1, "the benchmark sends exactly one request per model, sequentially")
        check(calls.allSatisfy { $0.text == benchmark.sample && $0.settings.target == settings.target
              && $0.key == keys[$0.settings.provider] }, "each request uses the same bounded sample, target and matching provider key")
        check(benchmark.fastest?.model == "tencent/Hunyuan-MT-7B", "only successful translations are ranked and the fastest is first")
        if let result = benchmark.rankedEntries.first, case .success(let metric) = result.state {
            check(metric.seconds == 0.5 && metric.charactersPerSecond == Double(benchmark.sample.count) / 0.5,
                  "complete-request latency and source characters per second use a monotonic measurement")
        } else { check(false, "a successful translation provides measured speed") }
        check(benchmark.entries.filter { if case .failed(let reason) = $0.state { return reason.contains("限流") }; return false }.count == 2,
              "rate-limited models remain visible as failures instead of winning a fast-error ranking")
        check(progress.contains(1) && progress.contains(7) && benchmark.completedCount == 7 && !benchmark.isRunning,
              "progress arrives after individual results and the run finishes after all candidates")

        for custom in ["fixture-echo", "fixture-secret-error", "fixture-timeout"] {
            var config = TranslationSettings(); config.siliconFlowModel = custom
            let testFixture = BenchmarkFixture()
            let run = TranslationBenchmark(settings: config, keys: [.siliconFlow: "fixture-silicon"],
                translator: { try await testFixture.perform($0, $1, $2) }, timeout: 0.03, spacing: 0,
                now: { testFixture.clock.read() })
            _ = run.start(); await run.waitUntilFinished()
            let outcome = run.entries.first { $0.candidate.model == custom }!.state
            if case .failed(let reason) = outcome {
                check(!reason.contains("fixture-secret"), "\(custom) exposes only a safe failure reason")
                if custom == "fixture-echo" { check(reason.contains("原文"), "an unchanged source is not treated as a successful translation") }
                if custom == "fixture-timeout" {
                    let cancellations = await testFixture.cancellations
                    check(reason.contains("超时") && cancellations == 1,
                          "a slow model is bounded and its in-flight work is cancelled")
                }
            } else { check(false, "\(custom) is classified as a failed translation") }
        }
        var slowConfig = TranslationSettings(); slowConfig.siliconFlowModel = "fixture-timeout"
        let stopFixture = BenchmarkFixture()
        let stopped = TranslationBenchmark(settings: slowConfig, keys: [.siliconFlow: "fixture-silicon"],
            translator: { try await stopFixture.perform($0, $1, $2) }, timeout: 5, spacing: 0)
        _ = stopped.start()
        for _ in 0..<100 {
            if await stopFixture.calls.contains(where: { $0.settings.siliconFlowModel == "fixture-timeout" }) { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        stopped.stop(); check(!stopped.start(), "a new run waits for cancellation to finish")
        await stopped.waitUntilFinished()
        let cancellations = await stopFixture.cancellations
        check(!stopped.isRunning && !stopped.isStopping && stopped.entries.last?.state == .stopped
              && cancellations == 1, "stop cancels active work and marks unfinished models without losing completed results")
        if failures > 0 { print("\(failures) benchmark checks failed"); exit(1) }
        print("Benchmark checks passed with fixed samples and isolated credentials; no live provider called")
    }
}
