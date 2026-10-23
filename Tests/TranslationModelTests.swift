import Foundation

final class MemoryCredentials: TranslationCredentials {
    var values: [TranslationProvider: String] = [:]
    var reject: TranslationProvider?
    func read(_ provider: TranslationProvider) throws -> String? { values[provider] }
    func write(_ value: String?, for provider: TranslationProvider) throws {
        if reject == provider { throw TranslationFailure.credentials }
        values[provider] = value
    }
}

@main struct TranslationModelTests {
    static func main() {
        var failures = 0
        func check(_ name: String, _ body: () throws -> Bool) {
            do { if try body() { print("PASS \(name)") } else { failures += 1; print("FAIL \(name)") } }
            catch { failures += 1; print("FAIL \(name): \(error.localizedDescription)") }
        }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let suite = "com.local.screenclip.translation-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = MemoryCredentials()
        let store = TranslationSettingsStore(defaults: defaults, credentials: credentials)
        var settings = TranslationSettings(); settings.provider = .siliconFlow; settings.target = .english
        settings.siliconFlowModel = "tencent/Hunyuan-MT-7B"
        check("settings and provider-specific models survive restart") {
            try store.save(settings, keys: [.siliconFlow: "sample-secret-only-for-tests"])
            return TranslationSettingsStore(defaults: defaults, credentials: credentials).settings == settings
        }
        check("secrets are stored separately from preferences") {
            guard let data = defaults.data(forKey: "translationSettings.v1") else { return false }
            return credentials.values[.siliconFlow] == "sample-secret-only-for-tests"
                && !String(data: data, encoding: .utf8)!.contains("sample-secret")
        }
        check("blank key edits explicitly remove an existing secret") {
            try store.save(settings, keys: [.siliconFlow: ""])
            return try store.key(for: .siliconFlow) == nil
        }
        check("saving settings without a key edit preserves the secret") {
            try store.save(settings, keys: [.siliconFlow: "preserve-me"])
            try store.save(settings)
            return try store.key(for: .siliconFlow) == "preserve-me"
        }
        check("invalid models never change stored settings") {
            var invalid = settings; invalid.siliconFlowModel = "\n"
            return rejects { try store.save(invalid) } && store.settings == settings
        }
        check("failed Keychain writes retain previous settings") {
            credentials.reject = .glm
            var next = settings; next.provider = .glm
            defer { credentials.reject = nil }
            return rejects { try store.save(next, keys: [.glm: "test-key"]) } && store.settings == settings
        }
        check("text is split without losing or duplicating characters") {
            let text = String(repeating: "A sentence with punctuation.\n", count: 170) + "最后一段。"
            let parts = try TranslationText.chunks(text)
            return parts.count > 1 && parts.allSatisfy { $0.count <= 2_000 } && parts.joined() == text
        }
        check("empty and oversized documents are rejected rather than truncated") {
            rejects { _ = try TranslationText.chunks(" \n") }
                && rejects { _ = try TranslationText.chunks(String(repeating: "字", count: 24_001)) }
        }
        for provider in [TranslationProvider.siliconFlow, .glm] {
            check("\(provider.title) uses its own HTTPS endpoint and sends only text") {
                var config = settings; config.provider = provider
                let request = try ChatTranslation.request(text: "Hello world.", settings: config, key: "test-key")
                let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                let messages = json["messages"] as! [[String: String]]
                return request.url == provider.endpoint && request.httpMethod == "POST"
                    && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key"
                    && json["model"] as? String == config.model(for: provider)
                    && json["stream"] as? Bool == false && json["max_tokens"] as? Int == 512
                    && messages.last?["content"]?.contains("Hello world.") == true
                    && !String(data: request.httpBody!, encoding: .utf8)!.contains("image_url")
            }
        }
        check("keys containing line breaks cannot become HTTP headers") {
            rejects { _ = try ChatTranslation.request(text: "Hi", settings: settings, key: "key\r\nheader: bad") }
        }
        let valid = Data(#"{"choices":[{"finish_reason":"stop","message":{"content":" 你好。 "}}]}"#.utf8)
        check("the returned translation is extracted without changing its wording") { try ChatTranslation.decode(valid, status: 200) == "你好。" }
        check("authentication and quota errors never become translated text") {
            rejects { _ = try ChatTranslation.decode(valid, status: 401) }
                && rejects { _ = try ChatTranslation.decode(valid, status: 429) }
        }
        check("truncated and empty completions are rejected") {
            let truncated = Data(#"{"choices":[{"finish_reason":"length","message":{"content":"half"}}]}"#.utf8)
            let reasoning = Data(#"{"choices":[{"finish_reason":"stop","message":{"reasoning_content":"hidden"}}]}"#.utf8)
            return rejects { _ = try ChatTranslation.decode(truncated, status: 200) }
                && rejects { _ = try ChatTranslation.decode(reasoning, status: 200) }
        }
        if failures > 0 { print("\(failures) translation behavior checks failed"); exit(1) }
        print("All translation model checks passed")
    }
}
