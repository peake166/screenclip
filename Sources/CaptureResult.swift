import AppKit
import Carbon

/// A short-lived floating HUD pill for an image that has already been copied.
@MainActor final class CaptureResultController: NSObject, NSWindowDelegate {
    enum Phase: Equatable { case closed, ready, recognizing, copied, failed(String) }
    private let board: NSPasteboard
    private let recognize: (Raster) async throws -> String
    private let dismissAfter: TimeInterval
    private let recognitionTimeout: TimeInterval
    private let cancelKeys = HotKeys()
    private var source: Raster?
    private var sourceRegion: CaptureRegion?
    private var recognizedText: String?
    private var task: Task<Void, Never>?
    private var dismissal: DispatchWorkItem?
    private var deadline: DispatchWorkItem?
    private var generation = UUID()
    private var localMonitor: Any?, outsideMonitor: Any?
    private(set) var phase: Phase = .closed
    private(set) var panel: OverlayPanel?
    let status = NSTextField(labelWithString: "")
    let pinButton = PillActionButton(title: "贴图", symbolName: "pin", style: .tinted(.amber))
    let copyButton = PillActionButton(title: "复制文字", symbolName: "text.viewfinder", style: .tinted(.blue))
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()
    var onPin: ((Raster, CaptureRegion) -> Void)?

    init(pasteboard: NSPasteboard = .general, dismissAfter: TimeInterval = 15, recognitionTimeout: TimeInterval = 120,
         recognize: @escaping (Raster) async throws -> String = { try await TextRecognizer.recognizeDocument($0, maximumCharacters: nil).text }) {
        board = pasteboard; self.recognize = recognize
        self.dismissAfter = dismissAfter; self.recognitionTimeout = recognitionTimeout
        super.init()
        spinner.widthAnchor.constraint(equalToConstant: 15).isActive = true
        spinner.heightAnchor.constraint(equalToConstant: 15).isActive = true
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        statusIcon.heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    static func toolbarFrame(near selection: CGRect, visible: CGRect) -> CGRect {
        let width = min(368, visible.width - 16), height: CGFloat = 52
        let x = min(visible.maxX - width - 8, max(visible.minX + 8, selection.midX - width / 2))
        let below = selection.minY - height - 8
        let y = below >= visible.minY + 8 ? below
            : min(visible.maxY - height - 8, max(visible.minY + 8, selection.maxY + 8))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    func show(_ image: Raster, region: CaptureRegion, message: String, present: Bool = true) {
        close(); generation = UUID(); source = image; sourceRegion = region; phase = .ready
        let frame = Self.toolbarFrame(near: region.rect, visible: region.screen.visibleFrame)
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "截图操作"; panel.hasShadow = true; panel.delegate = self
        panel.becomesKeyOnlyIfNeeded = true
        panel.onCancel = { [weak self] in self?.close() }; self.panel = panel
        let surface = FrostedSurface(radius: 26); panel.contentView = surface

        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        statusIcon.contentTintColor = ScreenClipTone.green.foreground
        statusIcon.isHidden = false

        status.stringValue = message; status.toolTip = nil; status.textColor = .labelColor
        status.font = .systemFont(ofSize: 12, weight: .medium); status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true

        let divider = HairlineDivider(vertical: true)
        divider.heightAnchor.constraint(equalToConstant: 20).isActive = true

        pinButton.title = "贴图"; pinButton.isEnabled = true
        pinButton.fixedHeight = 30; pinButton.horizontalPadding = 10
        pinButton.toolTip = "将截图固定在屏幕上"
        pinButton.setAccessibilityLabel("贴到屏幕")
        pinButton.target = self; pinButton.action = #selector(pinScreenshot)

        copyButton.title = "复制文字"; copyButton.isEnabled = true
        copyButton.fixedHeight = 30; copyButton.horizontalPadding = 10
        copyButton.target = self; copyButton.action = #selector(copyText)

        let close = PillActionButton(symbolName: "xmark", style: .iconCircle, target: self, action: #selector(dismiss))
        close.fixedHeight = 26
        close.toolTip = "关闭（Esc）"
        close.setAccessibilityLabel("关闭截图操作")

        let row = NSStackView(views: [statusIcon, spinner, status, divider, pinButton, copyButton, close])
        row.distribution = .fill; row.spacing = 6; row.alignment = .centerY
        row.setCustomSpacing(8, after: status)
        row.setCustomSpacing(8, after: divider)
        row.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: surface.centerYAnchor)
        ])
        if present { panel.orderFrontRegardless(); installDismissalEvents() }
        armDismissal(after: dismissAfter)
    }

    @objc func pinScreenshot() {
        guard panel != nil, let image = source, let region = sourceRegion else { return }
        close()
        onPin?(image, region)
    }

    @objc func copyText() {
        guard panel != nil, phase != .recognizing else { return }
        if let recognizedText { copyRecognizedText(recognizedText); return }
        guard let source else { return }
        dismissal?.cancel(); dismissal = nil
        phase = .recognizing; status.stringValue = "正在识别…"; status.textColor = .screenClipSecondaryLabel
        status.toolTip = nil; copyButton.title = "复制文字"
        copyButton.isEnabled = false
        statusIcon.isHidden = true; spinner.isHidden = false; spinner.startAnimation(nil)
        let token = UUID(); generation = token
        let expectedChangeCount = board.changeCount, recognize = self.recognize
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.phase == .recognizing else { return }
                self.generation = UUID(); self.task?.cancel(); self.task = nil
                self.fail("识别超时，请重试")
            }
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, recognitionTimeout), execute: timeout)
        task = Task { [weak self] in
            do {
                let text = try await recognize(source).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.panel != nil else { return }
                guard !text.isEmpty else { throw TranslationFailure.noText }
                self.deadline?.cancel(); self.deadline = nil; self.task = nil
                self.recognizedText = text
                self.spinner.stopAnimation(nil); self.spinner.isHidden = true
                self.statusIcon.isHidden = false
                self.copyButton.isEnabled = true
                guard self.board.changeCount == expectedChangeCount else {
                    self.phase = .ready; self.status.stringValue = "文字已就绪，点击复制"
                    self.status.textColor = .labelColor
                    self.armDismissal(after: self.dismissAfter); return
                }
                self.copyRecognizedText(text)
            } catch {
                guard let self, self.generation == token, self.panel != nil else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func copyRecognizedText(_ text: String) {
        board.clearContents()
        guard board.setString(text, forType: .string) else { fail("复制失败，请重试"); return }
        phase = .copied; status.stringValue = "已复制文字"; status.textColor = .labelColor
        status.toolTip = nil
        statusIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        statusIcon.contentTintColor = ScreenClipTone.green.foreground
        statusIcon.isHidden = false; spinner.isHidden = true
        copyButton.title = "复制文字"; copyButton.isEnabled = true
        armDismissal(after: 3)
    }

    private func fail(_ message: String) {
        deadline?.cancel(); deadline = nil; task = nil
        phase = .failed(message); status.stringValue = message; status.toolTip = message
        status.textColor = ScreenClipTone.red.foreground
        statusIcon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        statusIcon.contentTintColor = ScreenClipTone.red.foreground
        statusIcon.isHidden = false
        spinner.stopAnimation(nil); spinner.isHidden = true
        copyButton.title = "重试取字"; copyButton.isEnabled = true
        armDismissal(after: dismissAfter)
    }

    private func armDismissal(after seconds: TimeInterval) {
        dismissal?.cancel()
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token, self.phase != .recognizing else { return }
                self.close()
            }
        }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }

    private func installDismissalEvents() {
        cancelKeys.register(id: CaptureHotKeyID.resultCancel, key: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.close() }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    if event.keyCode == kVK_Escape { self.close(); return true }
                } else if event.window !== self.panel { self.close() }
                return false
            }
            return consumed ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    @objc private func dismiss() { close() }
    func windowWillClose(_ notification: Notification) { close() }
    func close() {
        generation = UUID(); task?.cancel(); task = nil
        dismissal?.cancel(); dismissal = nil; deadline?.cancel(); deadline = nil
        cancelKeys.unregister(CaptureHotKeyID.resultCancel)
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        let old = panel; panel = nil; old?.delegate = nil; old?.orderOut(nil); old?.close()
        source = nil; sourceRegion = nil; recognizedText = nil; spinner.stopAnimation(nil); phase = .closed
    }
}
