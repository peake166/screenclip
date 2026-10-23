import AppKit

private final class PreviewCredentials: TranslationCredentials {
    func read(_ provider: TranslationProvider) throws -> String? { nil }
    func write(_ value: String?, for provider: TranslationProvider) throws { }
}

@main struct TranslationPreview {
    @MainActor static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let folder = URL(fileURLWithPath: ".build/previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let suite = "com.local.screenclip.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationSettingsStore(defaults: defaults, credentials: PreviewCredentials())
        func render(_ window: NSWindow, name: String, appearance: NSAppearance) throws {
            window.appearance = appearance; window.contentView!.appearance = appearance
            let view = window.contentView!
            view.layoutSubtreeIfNeeded()
            func verify(_ candidate: NSView) {
                guard !candidate.isHiddenOrHasHiddenAncestor else { return }
                if candidate is NSControl, candidate.bounds.width > 0, candidate.bounds.height > 0 {
                    let rect = candidate.convert(candidate.bounds, to: view)
                    if !view.bounds.insetBy(dx: -1, dy: -1).contains(rect) {
                        print("FAIL clipped \(name): \(type(of: candidate)) \(rect), window \(view.bounds)")
                        exit(1)
                    }
                }
                candidate.subviews.forEach(verify)
            }
            verify(view)
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
            print("Rendered \(name): \(bitmap.pixelsWide)x\(bitmap.pixelsHigh)")
            window.close()
        }
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let prefix = dark ? "dark" : "light"
            for provider in TranslationProvider.allCases {
                var settings = TranslationSettings(); settings.provider = provider
                try store.save(settings)
                try render(TranslationSettingsWindow(store: store), name: prefix + "-service-" + provider.rawValue, appearance: appearance)
            }
            try render(TranslationWindow(store: store), name: prefix + "-translation-empty", appearance: appearance)
        }
    }
}
