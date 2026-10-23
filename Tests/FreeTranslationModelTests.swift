import Foundation

@main enum FreeTranslationModelTests {
    static func main() throws {
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)")
            if !value { failures += 1 }
        }
        let freeSilicon = ["tencent/Hunyuan-MT-7B", "Qwen/Qwen2.5-7B-Instruct", "THUDM/GLM-4-9B-0414", "Qwen/Qwen3-8B"]
        check(TranslationProvider.siliconFlow.suggestedModels == freeSilicon,
              "the SiliconFlow menu contains the four verified free translation choices")
        check(TranslationProvider.glm.suggestedModels == ["glm-4.7-flash", "glm-4-flash-250414"],
              "the GLM menu offers verified free Flash versions without paid models")
        func body(_ provider: TranslationProvider, _ model: String, text: String = "Hello world.") throws -> [String: Any] {
            var config = TranslationSettings(); config.provider = provider; config.setModel(model, for: provider)
            let request = try ChatTranslation.request(text: text, settings: config, key: "fixture-only")
            return try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        }
        let old = try body(.glm, "glm-4-flash", text: String(repeating: "字", count: 2000))
        check((old["max_tokens"] as? Int ?? 8192) <= 4095 && old["thinking"] == nil,
              "legacy GLM-4-Flash stays within its 4095-token limit and receives no thinking option")
        let short = try body(.glm, "glm-4.7-flash")
        let long = try body(.glm, "glm-4.7-flash", text: String(repeating: "字", count: 2000))
        check((short["max_tokens"] as? Int) == 512 && (long["max_tokens"] as? Int) == 8192,
              "short and long translation pieces receive proportionate bounded output budgets")
        check((short["thinking"] as? [String: String])?["type"] == "disabled",
              "GLM-4.7 Flash keeps thinking disabled for direct translation")
        let dated = try body(.glm, "glm-4-flash-250414")
        check(dated["thinking"] == nil, "the dated GLM-4 Flash receives only supported request options")
        let hunyuan = try body(.siliconFlow, "tencent/Hunyuan-MT-7B")
        let messages = hunyuan["messages"] as? [[String: String]] ?? []
        check(messages.count == 1 && messages.first?["role"] == "user"
              && hunyuan["temperature"] as? Double == 0.7 && hunyuan["top_p"] as? Double == 0.6,
              "Hunyuan uses a single translation prompt and its recommended sampling parameters")
        let qwen = try body(.siliconFlow, "Qwen/Qwen3-8B")
        check(qwen["enable_thinking"] as? Bool == false, "Qwen3 translation disables reasoning")
        let instruct = try body(.siliconFlow, "THUDM/GLM-4-9B-0414")
        check(instruct["enable_thinking"] == nil && instruct["thinking"] == nil,
              "non-thinking SiliconFlow models do not receive reasoning switches")
        if failures > 0 { print("\(failures) free-model checks failed"); exit(1) }
        print("All free-model request checks passed without API calls")
    }
}
