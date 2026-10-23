import AppKit

private final class OverlayTestCredentials: TranslationCredentials {
    func read(_ provider: TranslationProvider) throws -> String? { nil }
    func write(_ value: String?, for provider: TranslationProvider) throws { }
}

private final class FocusPreviewScene: NSView {
    override var isFlipped: Bool { true }
}

@main struct InPlaceOverlayTests {
    @MainActor static func main() async throws {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: Bool, _ name: String) {
            print("\(value ? "PASS" : "FAIL") \(name)"); if !value { failures += 1 }
        }
        func settled(_ overlay: TranslationOverlayController) async {
            for _ in 0..<2000 where overlay.phase.isBusy { try? await Task.sleep(nanoseconds: 5_000_000) }
        }
        let suite = "com.local.screenclip.overlay-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TranslationSettingsStore(defaults: defaults, credentials: OverlayTestCredentials())
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let folder = URL(fileURLWithPath: ".build/previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func fixture(dark: Bool) throws -> Raster {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 700,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            (dark ? NSColor(calibratedWhite: 0.1, alpha: 1) : .white).setFill()
            CGRect(x: 0, y: 0, width: 1200, height: 700).fill()
            for (text, y, font) in [("Open settings", 600.0, 44.0), ("Translation remains in the selected area.", 480.0, 30.0),
                                    ("Read the image without moving to another window.", 440.0, 30.0)] {
                (text as NSString).draw(at: CGPoint(x: 64, y: y), withAttributes: [
                    .font: NSFont.systemFont(ofSize: font), .foregroundColor: dark ? NSColor.white : .black
                ])
            }
            NSColor.systemTeal.setFill(); CGRect(x: 880, y: 80, width: 240, height: 250).fill()
            NSGraphicsContext.restoreGraphicsState()
            return try Raster(rep.cgImage!)
        }
        func render(_ view: NSView, _ name: String) throws {
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
        }
        let focusView = TranslationFocusView(screenFrame: CGRect(x: -800, y: 100, width: 160, height: 100),
            selection: CGRect(x: -760, y: 140, width: 60, height: 30))
        check(focusView.cutout == CGRect(x: 40, y: 30, width: 60, height: 30),
              "the focus cutout maps negative display coordinates without changing the selected region")
        let focusBitmap = focusView.bitmapImageRepForCachingDisplay(in: focusView.bounds)!
        focusView.cacheDisplay(in: focusView.bounds, to: focusBitmap)
        func alpha(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
            focusBitmap.colorAt(x: Int(x * CGFloat(focusBitmap.pixelsWide) / 160),
                                y: Int(y * CGFloat(focusBitmap.pixelsHigh) / 100))!.alphaComponent
        }
        check(alpha(10, 10) > 0.4 && alpha(10, 10) < 0.5, "the area surrounding the screenshot is visibly dimmed")
        check(alpha(70, 45) < 0.01, "the screenshot cutout remains completely undimmed")
        let otherDisplay = TranslationFocusView(screenFrame: CGRect(x: 0, y: 0, width: 160, height: 100),
            selection: CGRect(x: -760, y: 140, width: 60, height: 30))
        check(otherDisplay.cutout == nil, "another monitor never receives a misplaced bright cutout")
        let image = try fixture(dark: false)
        let doc = try TextRecognizer.recognizeDocumentImage(image.cgImage())
        check(doc.blocks.count == 2, "the generated screenshot yields two independent OCR paragraphs")
        guard let screen = NSScreen.main else { fatalError("No screen for native geometry checks") }
        let region = CaptureRegion(screen: screen, rect: CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 120, width: 600, height: 350))
        let native = CommandLine.arguments.contains("--native")
        if native {
            let start = Date()
            let overlay = TranslationOverlayController(store: store)
            overlay.begin(image, region: region, present: false); await settled(overlay)
            check(overlay.phase == .finished, "real local OCR and installed Apple translation complete the overlay workflow")
            let text = overlay.canvas?.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.joined() ?? ""
            check(text.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil,
                  "the native overlay contains actual Chinese translation rather than fixture responses")
            if let canvas = overlay.canvas { try render(canvas, "inplace-native") }
            print("Native fixture elapsed: \(Int(Date().timeIntervalSince(start) * 1000))ms")
            if case .failed(let message) = overlay.phase { print("Native fixture failure: \(message)") }
            overlay.close()
        } else {
            var settings = TranslationSettings(); settings.provider = .glm
            try store.save(settings)
            var recognitions = 0, calls = 0, fail = true, closes = 0
            var targets: [TranslationTarget] = []
            let long = String(repeating: "完整译文会保留，并可以展开阅读。", count: 120)
            let overlay = TranslationOverlayController(store: store, recognize: { _ in recognitions += 1; return doc }, translate: { text, settings in
                calls += 1; targets.append(settings.target)
                if text.contains("Translation"), fail { throw TranslationFailure.network }
                return text.contains("Open settings") ? "打开设置" : long
            }, pasteboard: board)
            overlay.onClose = { closes += 1 }
            overlay.begin(image, region: region, present: false); await settled(overlay)
            check(overlay.panel?.frame == region.rect, "the result panel occupies the exact selected global screen rectangle")
            check(overlay.focusBackdrops.count == NSScreen.screens.count,
                  "translation creates one focus backdrop for each display")
            check(overlay.focusBackdrops.allSatisfy { $0.ignoresMouseEvents && !$0.canBecomeKey && $0.level.rawValue < overlay.panel!.level.rawValue },
                  "backdrops remain below the translation and cannot steal mouse or keyboard input")
            check(overlay.toolbar?.retryButton.isHidden == false && overlay.toolbar?.status.stringValue.contains("网络") == true,
                  "a failed paragraph shows its cause and a retry action on the compact toolbar")
            check(overlay.canvas?.subviews.contains { ($0 as? NSTextField)?.stringValue == "打开设置" } == true,
                  "successful translated text is rendered at its source position before retry")
            try render(overlay.canvas!, "inplace-partial")
            try render(overlay.toolbar!.contentView!, "inplace-error-toolbar")
            overlay.toolbar?.originalButton.performClick(nil)
            check(overlay.canvas?.subviews.filter { $0 is NSTextField }.allSatisfy(\.isHidden) == true,
                  "the original button reveals the untouched screenshot")
            check(overlay.focusBackdrops.count == NSScreen.screens.count, "original-image comparison retains the focus effect")
            overlay.toolbar?.copyButton.performClick(nil)
            check(board.string(forType: .string) == doc.text, "copy-original writes the recognized text to the isolated test clipboard")
            overlay.toolbar?.originalButton.performClick(nil)
            fail = false; overlay.toolbar?.retryButton.performClick(nil); await settled(overlay)
            check(overlay.phase == .finished && recognitions == 1 && calls == 3,
                  "the native retry button resumes the failed paragraph without repeating OCR or successful provider work")
            check(overlay.canvas?.overflowCount == 1 && overlay.toolbar?.status.stringValue.contains("展开") == true,
                  "long translations expose an expansion affordance instead of shrinking to unreadable type")
            let longField = overlay.canvas?.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == long }
            check(longField?.cell?.wraps == true && (longField?.maximumNumberOfLines ?? 0) > 1,
                  "the visible long translation wraps over multiple lines before its expansion point")
            overlay.toolbar?.contentView?.layoutSubtreeIfNeeded()
            let root = overlay.toolbar!.contentView!
            let close = root.subviews.flatMap { $0.subviews }.first { $0.toolTip == "关闭（Esc）" }
            check(close.map { $0.convert($0.bounds, to: root).maxX >= root.bounds.maxX - 20 } == true,
                  "compact toolbar controls remain grouped at the trailing edge")
            try render(root, "inplace-toolbar-complete")
            overlay.toolbar?.copyButton.performClick(nil)
            check(board.string(forType: .string) == "打开设置\n\n" + long, "copy translation includes the complete untruncated result")
            try render(overlay.canvas!, "inplace-light")
            try render(overlay.toolbar!.contentView!, "inplace-toolbar")
            var changed = settings; changed.target = .english
            try store.save(changed); overlay.settingsChanged()
            check(overlay.toolbar?.retryButton.title == "重译", "saving another target offers retranslation in the same selected area")
            overlay.toolbar?.retryButton.performClick(nil); await settled(overlay)
            check(recognitions == 1 && targets.suffix(2).allSatisfy { $0 == .english },
                  "retranslation applies updated settings while reusing the screenshot geometry")
            overlay.toolbar?.cancelOperation(nil)
            check(overlay.panel == nil && overlay.toolbar == nil && overlay.canvas == nil && overlay.phase == .idle && closes == 1,
                  "Escape closes both surfaces and cancels the translation workflow")
            check(overlay.focusBackdrops.isEmpty, "Escape removes every dimming backdrop along with the translation")
            let dark = try fixture(dark: true)
            let darkCanvas = TranslationCanvas(image: dark, size: region.rect.size)
            darkCanvas.update(document: doc, translations: [doc.blocks[0].id: "打开设置", doc.blocks[1].id: "译文保留在框选的位置。"], original: false)
            try render(darkCanvas, "inplace-dark")
            let preview = TranslationCanvas(image: image, size: region.rect.size)
            preview.update(document: doc, translations: [doc.blocks[0].id: "打开设置", doc.blocks[1].id: "译文保留在框选的位置。"], original: false)
            try render(preview, "inplace-normal")
            try image.png().write(to: folder.appendingPathComponent("inplace-source.png"))
            let scene = FocusPreviewScene(frame: CGRect(x: 0, y: 0, width: 900, height: 560))
            scene.appearance = NSAppearance(named: .aqua)
            scene.wantsLayer = true; scene.layer?.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
            let heading = NSTextField(labelWithString: "原位翻译效果示意")
            heading.font = .systemFont(ofSize: 20, weight: .medium); heading.frame = CGRect(x: 24, y: 24, width: 400, height: 28)
            scene.addSubview(heading)
            for (index, title) in ["文档", "最近打开", "收藏"].enumerated() {
                let label = NSTextField(labelWithString: title)
                label.font = .systemFont(ofSize: 14); label.frame = CGRect(x: 24, y: 110 + index * 38, width: 110, height: 24)
                scene.addSubview(label)
            }
            let focus = TranslationFocusView(screenFrame: scene.bounds, selection: CGRect(x: 150, y: 120, width: 600, height: 350))
            scene.addSubview(focus)
            preview.frame.origin = CGPoint(x: 150, y: 90); scene.addSubview(preview)
            let controls = OverlayToolbar()
            controls.status.stringValue = "系统翻译 · 已完成"; controls.retryButton.isHidden = true
            let controlsView = controls.contentView!
            controls.contentView = nil; controlsView.frame.origin = CGPoint(x: 180, y: 466)
            scene.addSubview(controlsView)
            try render(scene, "inplace-focus")
            controls.close()
        }
        if failures > 0 { exit(1) }
    }
}
