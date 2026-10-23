import Foundation

private final class FixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var statusValue = 200, callValue = 0, stopValue = 0
    private static var bodyValue = Data(), suspended = false, headerValues: [String: String] = [:]
    static var status: Int { get { lock.withLock { statusValue } } set { lock.withLock { statusValue = newValue } } }
    static var body: Data { get { lock.withLock { bodyValue } } set { lock.withLock { bodyValue = newValue } } }
    static var calls: Int { lock.withLock { callValue } }
    static var stops: Int { lock.withLock { stopValue } }
    static var suspend: Bool { get { lock.withLock { suspended } } set { lock.withLock { suspended = newValue } } }
    static var headers: [String: String] { get { lock.withLock { headerValues } } set { lock.withLock { headerValues = newValue } } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.lock.withLock { () -> (Int, Data, Bool, [String: String]) in
            Self.callValue += 1
            return (Self.statusValue, Self.bodyValue, Self.suspended, Self.headerValues)
        }
        guard !fixture.2 else { return }
        let headers = fixture.3.merging(["Content-Type": "application/json"]) { value, _ in value }
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.0, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { Self.lock.withLock { Self.stopValue += 1 } }
}

@main struct CloudTests {
    static func main() async {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            if value { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        let cloud = CloudTranslation(configuration: config)
        var settings = TranslationSettings(); settings.provider = .glm
        FixtureProtocol.body = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"你好，世界。"}}]}"#.utf8)
        do {
            let value = try await cloud.translate("Hello world.", settings: settings, key: "fixture-only")
            check(value == "你好，世界。" && FixtureProtocol.calls == 1, "the real URLSession path decodes a compatible API response")
        } catch { check(false, "URLSession fixture completes") }
        FixtureProtocol.status = 401; FixtureProtocol.body = Data(#"{"error":{"message":"fixture-only secret details"}}"#.utf8)
        do { _ = try await cloud.translate("Hi", settings: settings, key: "fixture-only"); check(false, "authentication failure is surfaced") }
        catch { check(FixtureProtocol.calls == 2 && !error.localizedDescription.contains("fixture-only"), "failed authentication is not retried and does not expose response secrets") }
        FixtureProtocol.status = 200; FixtureProtocol.suspend = true
        let stopsBeforeCancellation = FixtureProtocol.stops
        let task = Task { try await cloud.translate("Hi", settings: settings, key: "fixture-only") }
        for _ in 0..<100 where FixtureProtocol.calls < 3 { try? await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        do { _ = try await task.value; check(false, "cancellation stops the request") }
        catch is CancellationError {
            for _ in 0..<100 where FixtureProtocol.stops == stopsBeforeCancellation { try? await Task.sleep(nanoseconds: 1_000_000) }
            check(FixtureProtocol.stops - stopsBeforeCancellation == 1, "cancelling translation stops the in-flight URLSession request")
        }
        catch { check(false, "cancellation preserves cancellation semantics") }
        FixtureProtocol.suspend = false
        let successBody = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":"完成"}}]}"#.utf8)
        func failure(code: String?, model: String, status: Int = 429, headers: [String: String] = [:]) async -> TranslationFailure? {
            let configuration: TranslationSettings = { var value = settings; value.glmModel = model; return value }()
            FixtureProtocol.status = status; FixtureProtocol.headers = headers
            FixtureProtocol.body = Data(("{\"error\":{\"code\":\"" + (code ?? "unlisted-secret-code") + "\",\"message\":\"fixture-secret-message-do-not-log\"}}").utf8)
            do { _ = try await cloud.translate("private fixture text", settings: configuration, key: "fixture-private-key"); return nil }
            catch let error as TranslationFailure { return error }
            catch { return nil }
        }
        let mappingCases = [("1113", "balance"), ("1308", "quota"), ("1302", "rate"), ("1305", "overload")]
        for (code, suffix) in mappingCases {
            let before = FixtureProtocol.calls
            let error = await failure(code: code, model: "fixture-map-" + suffix)
            let correct: Bool
            switch (code, error) {
            case ("1113", .rejected(402)?), ("1308", .quotaExceeded?), ("1302", .rejected(429)?), ("1305", .overloaded?): correct = true
            default: correct = false
            }
            check(correct && FixtureProtocol.calls == before + 1, "GLM business code \(code) maps to a safe specific failure without retry")
            check(error?.localizedDescription.contains("fixture-") == false, "GLM business code \(code) never exposes response messages or request secrets")
        }
        for code in ["1113", "1308"] {
            let model = "fixture-no-cooldown-" + code
            _ = await failure(code: code, model: model, headers: ["Retry-After": "60"])
            FixtureProtocol.status = 200; FixtureProtocol.body = successBody; FixtureProtocol.headers = [:]
            let configuration: TranslationSettings = { var value = settings; value.glmModel = model; return value }()
            let started = Date()
            let before = FixtureProtocol.calls
            let task = Task { try await cloud.translate("Hi", settings: configuration, key: "fixture-only") }
            // Bound this test even when an incorrect implementation cools down quota errors for sixty seconds.
            try? await Task.sleep(nanoseconds: 100_000_000)
            if FixtureProtocol.calls == before { task.cancel() }
            do { _ = try await task.value; check(Date().timeIntervalSince(started) < 0.5, "GLM \(code) does not impose a retry cooldown") }
            catch { check(false, "GLM \(code) does not impose a retry cooldown") }
        }

        _ = await failure(code: "1302", model: "fixture-shared-rate", headers: ["Retry-After": "1"])
        let callsAfterLimit = FixtureProtocol.calls
        try? await Task.sleep(nanoseconds: 80_000_000)
        check(FixtureProtocol.calls == callsAfterLimit, "a rate limit never automatically resends the failed request")
        FixtureProtocol.status = 200; FixtureProtocol.body = successBody; FixtureProtocol.headers = [:]
        let otherCloud = CloudTranslation(configuration: config)
        var sameModel = settings; sameModel.glmModel = "fixture-shared-rate"
        let waitStarted = Date()
        let waiting = Task { try await otherCloud.translate("Hi", settings: sameModel, key: "fixture-only") }
        let alsoWaiting = Task { try await cloud.translate("Hi again", settings: sameModel, key: "fixture-only") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        check(FixtureProtocol.calls == callsAfterLimit, "provider/model cooldown is shared by separate transport instances")
        var differentModel = settings; differentModel.glmModel = "fixture-unrelated-model"
        do {
            _ = try await otherCloud.translate("Hi", settings: differentModel, key: "fixture-only")
            check(FixtureProtocol.calls == callsAfterLimit + 1, "a different model does not inherit another model's cooldown")
        } catch { check(false, "unrelated model completes") }
        do {
            let value = try await waiting.value
            let otherValue = try await alsoWaiting.value
            check(value == "完成" && otherValue == "完成" && Date().timeIntervalSince(waitStarted) >= 0.8 && FixtureProtocol.calls == callsAfterLimit + 3,
                  "concurrent explicit requests share Retry-After and each send exactly once")
        } catch { check(false, "explicit request after cooldown completes") }

        _ = await failure(code: "1305", model: "fixture-cancel-cooldown", headers: ["Retry-After": "60"])
        let callsBeforeCooldownCancel = FixtureProtocol.calls
        FixtureProtocol.status = 200; FixtureProtocol.body = successBody; FixtureProtocol.headers = [:]
        var overload = settings; overload.glmModel = "fixture-cancel-cooldown"
        let cooling = Task { try await otherCloud.translate("Hi", settings: overload, key: "fixture-only") }
        try? await Task.sleep(nanoseconds: 60_000_000); cooling.cancel()
        do { _ = try await cooling.value; check(false, "cooldown cancellation is surfaced") }
        catch is CancellationError {
            check(FixtureProtocol.calls == callsBeforeCooldownCancel, "cancelling during shared cooldown sends no HTTP request")
        } catch { check(false, "cooldown cancellation preserves cancellation semantics") }

        let unknown = await failure(code: "not-allowlisted-secret", model: "fixture-generic-429")
        if case .rejected(429)? = unknown {
            check(!unknown!.localizedDescription.contains("secret"), "unknown business codes stay generic and do not expose raw response details")
        } else { check(false, "unknown rate-limit response remains a generic 429") }
        let genericCalls = FixtureProtocol.calls
        FixtureProtocol.status = 200; FixtureProtocol.body = successBody; FixtureProtocol.headers = [:]
        var genericSettings = settings; genericSettings.glmModel = "fixture-generic-429"
        let genericWait = Task { try await otherCloud.translate("Hi", settings: genericSettings, key: "fixture-only") }
        try? await Task.sleep(nanoseconds: 60_000_000); genericWait.cancel()
        do { _ = try await genericWait.value; check(false, "generic 429 imposes the default cooldown") }
        catch is CancellationError { check(FixtureProtocol.calls == genericCalls, "generic 429 cools down without resending or exposing raw errors") }
        catch { check(false, "generic cooldown cancellation preserves cancellation semantics") }

        _ = await failure(code: nil, model: "fixture-auth-no-cooldown", status: 401, headers: ["Retry-After": "60"])
        FixtureProtocol.status = 200; FixtureProtocol.body = successBody; FixtureProtocol.headers = [:]
        var authSettings = settings; authSettings.glmModel = "fixture-auth-no-cooldown"
        let authStarted = Date(), authCalls = FixtureProtocol.calls
        let authRetry = Task { try await cloud.translate("Hi", settings: authSettings, key: "fixture-only") }
        try? await Task.sleep(nanoseconds: 100_000_000)
        if FixtureProtocol.calls == authCalls { authRetry.cancel() }
        do { _ = try await authRetry.value; check(Date().timeIntervalSince(authStarted) < 0.5, "authentication errors ignore Retry-After and do not create a cooldown") }
        catch { check(false, "authentication errors do not create a cooldown") }

        FixtureProtocol.status = 429; FixtureProtocol.body = Data(#"{"error":{"code":1308,"message":"fixture-secret"}}"#.utf8)
        var numericSettings = settings; numericSettings.glmModel = "fixture-numeric-code"
        do { _ = try await cloud.translate("Hi", settings: numericSettings, key: "fixture-only"); check(false, "numeric GLM error code is handled") }
        catch TranslationFailure.quotaExceeded { check(true, "numeric GLM quota codes retain the same safe classification") }
        catch { check(false, "numeric GLM quota codes retain the same safe classification") }

        FixtureProtocol.status = 429; FixtureProtocol.body = Data(#"{"error":{"code":"1308","message":"fixture-secret"}}"#.utf8)
        var silicon = settings; silicon.provider = .siliconFlow; silicon.siliconFlowModel = "fixture-provider-specific"
        do { _ = try await cloud.translate("Hi", settings: silicon, key: "fixture-only"); check(false, "provider-specific codes are isolated") }
        catch TranslationFailure.rejected(429) { check(true, "GLM business codes are not applied to another provider") }
        catch { check(false, "GLM business codes are not applied to another provider") }
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        check(CloudTranslation.retryDelay("12", now: fixedNow) == 12 && CloudTranslation.retryDelay("0", now: fixedNow) == 0,
              "Retry-After accepts valid whole seconds including zero")
        check(CloudTranslation.retryDelay("999999999999999999999", now: fixedNow) == 60,
              "Retry-After cooldown is bounded to sixty seconds")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let future = formatter.string(from: fixedNow.addingTimeInterval(20))
        let past = formatter.string(from: fixedNow.addingTimeInterval(-20))
        check(CloudTranslation.retryDelay(future, now: fixedNow) == 20 && CloudTranslation.retryDelay(past, now: fixedNow) == 0,
              "Retry-After accepts HTTP dates and does not wait for a past date")
        check([nil, "", "garbage", "-3", "1.5"].allSatisfy { CloudTranslation.retryDelay($0, now: fixedNow) == 3 },
              "missing or invalid Retry-After uses a short three-second cooldown")
        if failures > 0 { print("\(failures) transport checks failed"); exit(1) }
        print("All cloud transport checks passed using a local URLProtocol fixture")
    }
}
