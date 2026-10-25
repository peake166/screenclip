import AppKit

private final class TextCopyCredentials: TranslationCredentials {
    func read(_ provider: TranslationProvider) throws -> String? { nil }
    func write(_ value: String?, for provider: TranslationProvider) throws { }
}

@main struct TranslationTextCopyTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 }
        }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func click(_ button: NSButton?) {
            guard let button, button.isEnabled, let action = button.action else { return }
            NSApp.sendAction(action, to: button.target, from: button)
        }
        let suite = "com.local.screenclip.text-copy." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationSettingsStore(defaults: defaults, credentials: TextCopyCredentials())
        var settings = TranslationSettings(); settings.provider = .glm; try store.save(settings)
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let raster = Raster(width: 40, height: 30, bytes: [UInt8](repeating: 255, count: 40 * 30 * 4))
        let document = TextLayout.document(lines: [OCRLine(text: "Copy this original text.", rect: CGRect(x: 2, y: 2, width: 36, height: 8))],
                                           imageSize: CGSize(width: 40, height: 30))
        guard let screen = NSScreen.main else { fatalError("A logged-in desktop is required") }
        let region = CaptureRegion(screen: screen, rect: screen.visibleFrame.insetBy(dx: 120, dy: 120))
        var recognitions = 0
        let overlay = TranslationOverlayController(store: store, recognize: { _ in recognitions += 1; return document },
            translate: { _, _ in throw TranslationFailure.network }, pasteboard: board)
        overlay.begin(raster, region: region, present: false)
        for _ in 0..<500 where overlay.phase.isBusy { try await Task.sleep(nanoseconds: 2_000_000) }
        let buttons = all(overlay.toolbar!.contentView!).compactMap { $0 as? NSButton }
        let original = buttons.first { $0.title == "复制原文" }
        check(original?.isEnabled == true, "original text is directly copyable when translation fails, without toggling the image")
        click(original)
        check(board.string(forType: .string) == document.text && recognitions == 1,
              "copy-original reuses the existing OCR result and writes the full recognized text")
        check(buttons.first { $0.title == "复制译文" }?.isEnabled == false,
              "incomplete translations remain unavailable for copying")
        overlay.close()

        var releaseTranslation: CheckedContinuation<String, Never>?
        let pending = TranslationOverlayController(store: store, recognize: { _ in recognitions += 1; return document },
            translate: { _, _ in await withCheckedContinuation { releaseTranslation = $0 } }, pasteboard: board)
        pending.begin(raster, region: region, present: false)
        for _ in 0..<500 where releaseTranslation == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        check(pending.toolbar?.copyOriginalButton.isEnabled == true && pending.toolbar?.copyButton.isEnabled == false,
              "copy-original becomes available while the translation request is still pending")
        click(pending.toolbar?.copyOriginalButton)
        check(board.string(forType: .string) == document.text, "copying source text never waits for the translation provider")
        releaseTranslation?.resume(returning: "这是译文。"); releaseTranslation = nil
        for _ in 0..<500 where pending.phase.isBusy { try await Task.sleep(nanoseconds: 2_000_000) }
        click(pending.toolbar?.originalButton)
        click(pending.toolbar?.copyButton)
        check(board.string(forType: .string) == "这是译文。", "copy-translation remains independent of the original-image comparison toggle")
        click(pending.toolbar?.copyOriginalButton)
        check(board.string(forType: .string) == document.text && recognitions == 2, "both copy actions share the single recognition for that capture")
        pending.close()

        var windowRecognitions = 0
        let window = TranslationWindow(store: store, recognize: { _ in windowRecognitions += 1; return document.text },
            translate: { _, _ in throw TranslationFailure.network }, pasteboard: board)
        window.begin(raster, present: false)
        let windowButtons = all(window.contentView!).compactMap { $0 as? NSButton }
        let windowOriginal = windowButtons.first { $0.title == "复制原文" }
        for _ in 0..<500 where windowOriginal?.isEnabled != true { try await Task.sleep(nanoseconds: 2_000_000) }
        click(windowOriginal)
        check(board.string(forType: .string) == document.text && windowRecognitions == 1 && windowOriginal?.isEnabled == true,
              "the long-screenshot translation window also exposes direct copy-original without a tab switch")
        check(windowButtons.first { $0.title == "复制译文" }?.isEnabled == false,
              "the long-screenshot translation window does not copy partial or failed translations")
        window.close()
        if failures > 0 { exit(1) }
    }
}
