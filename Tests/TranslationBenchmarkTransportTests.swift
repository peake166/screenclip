import Foundation

private final class BenchmarkAPI: URLProtocol {
    struct Call { let host: String; let authorization: String; let model: String; let sample: String }
    private static let lock = NSLock()
    private static var recorded: [Call] = [], stopped = 0, suspendEveryRequest = false
    private var waiting = false
    static var calls: [Call] { lock.withLock { recorded } }
    static var cancellations: Int { lock.withLock { stopped } }
    static func reset(suspend: Bool) { lock.withLock { recorded = []; stopped = 0; suspendEveryRequest = suspend } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable && data.count < 65_536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let model = body["model"] as? String ?? ""
        let messages = body["messages"] as? [[String: String]] ?? []
        let call = Call(host: request.url?.host ?? "", authorization: request.value(forHTTPHeaderField: "Authorization") ?? "",
                        model: model, sample: messages.last?["content"] ?? "")
        let suspend = Self.lock.withLock {
            Self.recorded.append(call)
            return Self.suspendEveryRequest || model == "fixture-timeout"
        }
        if suspend { waiting = true; return }
        let failed = model == "THUDM/GLM-4-9B-0414"
        let response = HTTPURLResponse(url: request.url!, statusCode: failed ? 429 : 200, httpVersion: "HTTP/1.1",
                                      headerFields: ["Content-Type": "application/json", "Retry-After": "0"])!
        let responseBody = failed ? #"{"error":{"message":"fixture-private-provider-message"}}"#
            : #"{"choices":[{"finish_reason":"stop","message":{"content":"会议将于周五上午十点开始。"}}]}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if waiting { Self.lock.withLock { Self.stopped += 1 } } }
}

@main struct TranslationBenchmarkTransportTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [BenchmarkAPI.self]
        let cloud = CloudTranslation(configuration: config)
        var settings = TranslationSettings(); settings.siliconFlowModel = "fixture-timeout"
        let keys: [TranslationProvider: String] = [.siliconFlow: "fixture-silicon-key", .glm: "fixture-glm-key"]
        let benchmark = TranslationBenchmark(settings: settings, keys: keys,
            translator: { try await cloud.translate($0, settings: $1, key: $2) }, timeout: 0.08, spacing: 0)
        BenchmarkAPI.reset(suspend: false)
        _ = benchmark.start(); await benchmark.waitUntilFinished()
        let calls = BenchmarkAPI.calls
        check(calls.count == 7 && Set(calls.map(\.model)).count == 7,
              "the real cloud transport sends exactly one HTTP request for every planned model")
        check(calls.allSatisfy {
            ($0.host == "api.siliconflow.cn" && $0.authorization == "Bearer fixture-silicon-key")
            || ($0.host == "open.bigmodel.cn" && $0.authorization == "Bearer fixture-glm-key")
        }, "each provider receives only its matching credential at its existing endpoint")
        check(calls.allSatisfy { $0.sample.contains(benchmark.sample) }, "the normal request builder uses the same synthetic source across providers")
        check(BenchmarkAPI.cancellations == 1 && benchmark.completedCount == 7,
              "a timed-out URLSession task is cancelled and the remaining provider still completes")
        let reasons = benchmark.entries.compactMap { entry -> String? in if case .failed(let reason) = entry.state { return reason }; return nil }
        check(reasons.count == 2 && reasons.contains(where: { $0.contains("限流") })
              && reasons.contains(where: { $0.contains("超时") }) && !reasons.contains(where: { $0.contains("fixture-private") }),
              "HTTP errors and deadlines remain separate safe failures with no automatic retries")
        BenchmarkAPI.reset(suspend: true)
        _ = benchmark.start()
        for _ in 0..<100 { if !BenchmarkAPI.calls.isEmpty { break }; try? await Task.sleep(nanoseconds: 1_000_000) }
        benchmark.stop(); check(!benchmark.start(), "restart is blocked until the previous HTTP cancellation drains")
        await benchmark.waitUntilFinished()
        check(BenchmarkAPI.calls.count == 1 && BenchmarkAPI.cancellations == 1 && !benchmark.isStopping,
              "stopping a benchmark cancels the active HTTP request and sends none of the queued models")
        if failures > 0 { print("\(failures) benchmark transport checks failed"); exit(1) }
        print("Benchmark transport checks passed through URLSession with a local protocol fixture; no live API used")
    }
}
