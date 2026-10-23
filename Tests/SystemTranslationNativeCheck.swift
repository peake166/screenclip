// Optional local integration check. It only uses a fixed sample and already-installed languages.
import AppKit
import Translation

@main struct NativeTranslationCheck {
    @MainActor static func main() async {
        guard #available(macOS 26.0, *) else { print("SKIP direct translation requires macOS 26"); return }
        let status = await LanguageAvailability().status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        guard status == .installed else { print("SKIP English/Chinese languages are not installed; no download requested"); return }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let system = SystemTranslation()
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 25_000_000_000)
            if !Task.isCancelled { print("FAIL native translation did not finish within 25 seconds"); exit(1) }
        }
        defer { watchdog.cancel(); system.cancel() }
        do {
            for index in 1...3 {
                let start = Date()
                let value = try await system.translate("Hello world. Please copy this text.", to: .chinese)
                guard value.unicodeScalars.contains(where: { (0x3400...0x9fff).contains($0.value) }) else {
                    print("FAIL native translation did not produce Chinese text"); exit(1)
                }
                print("PASS actual installed-language translation \(index); milliseconds: \(Int(Date().timeIntervalSince(start) * 1000))")
            }
        } catch { print("FAIL native translation: \(error.localizedDescription)"); exit(1) }
    }
}
