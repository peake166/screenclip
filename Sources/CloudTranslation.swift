import Foundation
import OSLog

private actor TranslationCooldown {
    static let shared = TranslationCooldown()
    private var deadlines: [String: Date] = [:]
    func record(scope: String, seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        deadlines[scope] = max(deadlines[scope] ?? deadline, deadline)
    }
    func wait(scope: String) async throws {
        try Task.checkCancellation()
        while let deadline = deadlines[scope] {
            let seconds = deadline.timeIntervalSinceNow
            guard seconds > 0 else { deadlines[scope] = nil; break }
            try await Task.sleep(nanoseconds: UInt64(min(60, seconds) * 1_000_000_000))
            // Another response can extend the same shared deadline while sleeping.
            try Task.checkCancellation()
        }
    }
}

private final class NoTranslationRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class CloudTranslation {
    static func retryDelay(_ value: String?, now: Date = Date()) -> TimeInterval {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return 3 }
        if value.utf8.allSatisfy({ (48...57).contains($0) }), let seconds = Double(value) { return min(60, seconds) }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let deadline = formatter.date(from: value) else { return 3 }
        return min(60, max(0, deadline.timeIntervalSince(now)))
    }
    private let session: URLSession
    private let redirect = NoTranslationRedirect()
    private let logger = Logger(subsystem: "com.local.screenclip", category: "CloudTranslation")
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }
    func translate(_ text: String, settings: TranslationSettings, key: String) async throws -> String {
        let request = try ChatTranslation.request(text: text, settings: settings, key: key)
        let model = settings.model(for: settings.provider), scope = settings.provider.rawValue + ":" + settings.model(for: settings.provider)
        do {
            try await TranslationCooldown.shared.wait(scope: scope)
            try Task.checkCancellation()
            let started = Date()
            let (data, response) = try await session.data(for: request, delegate: redirect)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw TranslationFailure.network }
            let status = response.statusCode
            let code = settings.provider == .glm && !(200..<300).contains(status) ? Self.businessCode(data) : nil
            let accountProblem = code == "1113" || code == "1308" || status == 401 || status == 402
            let cooldown = !accountProblem && (status == 429 || code == "1302" || code == "1305")
                ? Self.retryDelay(response.value(forHTTPHeaderField: "Retry-After")) : 0
            if cooldown > 0 { await TranslationCooldown.shared.record(scope: scope, seconds: cooldown) }
            // Only bounded, non-content metadata is logged. Provider messages,
            // response bodies, API keys, and translated text never reach the log.
            logger.notice("Provider response: provider=\(settings.provider.rawValue, privacy: .public); model=\(model, privacy: .public); status=\(status); code=\(code ?? "none", privacy: .public); retry_seconds=\(cooldown); milliseconds=\(Int(Date().timeIntervalSince(started) * 1000))")
            switch code {
            case "1113": throw TranslationFailure.rejected(402)
            case "1308": throw TranslationFailure.quotaExceeded
            case "1302": throw TranslationFailure.rejected(429)
            case "1305": throw TranslationFailure.overloaded
            default: break
            }
            return try ChatTranslation.decode(data, status: response.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError {
            logger.error("Transport failed: provider=\(settings.provider.rawValue, privacy: .public); code=\(error.code.rawValue)")
            throw TranslationFailure.network
        }
        catch let error as TranslationFailure { throw error }
        catch { throw TranslationFailure.network }
    }
    private static func businessCode(_ data: Data) -> String? {
        guard data.count <= 2_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return nil }
        let code = error["code"] as? String ?? (error["code"] as? NSNumber)?.stringValue
        return ["1113", "1308", "1302", "1305"].contains(code ?? "") ? code : nil
    }
}
