import AppKit
import Carbon
import CoreGraphics
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let hotKeys = HotKeys()
    private let selector = SelectionController()
    private var session: LongCapture?
    private var selecting = false
    private var helpWindow: MainWindow?
    private let loginItems = LoginItemController(service: SystemLoginItemService())
    private let translationStore = TranslationSettingsStore(credentials: KeychainTranslationCredentials())
    private var translationWindow: TranslationWindow?
    private var translationOverlay: TranslationOverlayController?
    private var translationSettingsWindow: TranslationSettingsWindow?
    private let clipboardHistory = ClipboardHistory()
    private var clipboardWindow: ClipboardHistoryWindow?
    private let clipboardPaster = ClipboardPaster()
    private var clipboardTarget: ClipboardPasteTarget?
    private var captureMenuItems: [ShortcutAction: NSMenuItem] = [:]
    private var recordingShortcut = false
    private lazy var preferences = ShortcutPreferences { [weak self] bindings in
        self?.configureShortcuts(bindings, rollback: true) ?? false
    }
    private var priorApplication: NSRunningApplication?
    private var toast: NSPanel?
    private let captureResult = CaptureResultController()
    private var activationObserver: NSObjectProtocol?
    private var permissionAlertVisible = false
    private let logger = Logger(subsystem: "com.local.screenclip", category: "Capture")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditingMenu()
        priorApplication = NSWorkspace.shared.frontmostApplication
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.bundleIdentifier != "com.apple.WindowManager" else { return }
            MainActor.assumeIsolated { self?.priorApplication = app }
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "截图助手")
        if let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns"), let icon = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = icon
        }
        let menu = NSMenu()
        captureMenuItems[.copy] = add(menu, "截图并复制", #selector(captureSingle))
        captureMenuItems[.scroll] = add(menu, "滚动截图 / 完成", #selector(captureLong))
        captureMenuItems[.translate] = add(menu, "截图翻译", #selector(captureTranslate))
        captureMenuItems[.clipboard] = add(menu, "剪贴板历史", #selector(showClipboard))
        menu.addItem(.separator())
        add(menu, "打开窗口", #selector(showHelp))
        add(menu, "快捷键…", #selector(showShortcuts))
        add(menu, "翻译设置…", #selector(showTranslationSettings))
        add(menu, "截图权限…", #selector(requestPermission))
        menu.addItem(.separator())
        add(menu, "退出截图助手", #selector(quit))
        item.menu = menu
        let shortcutsOK = configureShortcuts(preferences.bindings, rollback: false)
        logger.notice("Started; shortcuts registered: \(shortcutsOK); screen permission: \(CGPreflightScreenCaptureAccess())")
        TextRecognizer.warmUp()
        clipboardHistory.start()
        if LoginItemLaunch.shouldShowWindow(for: NSAppleEventManager.shared().currentAppleEvent) {
            showHelp()
            if !shortcutsOK {
                helpWindow?.revealSettings()
                helpWindow?.showFeedback("快捷键被占用，请重新设置", isError: true)
            }
        } else {
            refreshPermissionLabel()
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self; menu.addItem(entry)
        return entry
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        logger.info("Application reopened")
        showHelp(); return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidBecomeActive(_ notification: Notification) {
        helpWindow?.updateLoginItem(loginItems.state)
    }

    @objc func showHelp() {
        captureResult.close()
        clipboardPaster.cancel(); clipboardWindow?.dismiss()
        rememberTarget()
        if helpWindow == nil {
            let icon = Bundle.main.path(forResource: "AppIcon", ofType: "icns").flatMap { NSImage(contentsOfFile: $0) }
            let window = MainWindow(icon: icon)
            window.onCapture = { [weak self] action in
                self?.performCapture(action)
            }
            window.onPermission = { [weak self] in self?.requestPermission() }
            window.onTranslationSettings = { [weak self] in self?.showTranslationSettings() }
            window.onLoginItemChange = { [weak self] enabled in
                guard let self else { return }
                let change = self.loginItems.setEnabled(enabled)
                self.helpWindow?.updateLoginItem(change.state)
                if let message = change.errorMessage { self.helpWindow?.showLoginItemError(message) }
            }
            window.onLoginItemSettings = { [weak self] in self?.loginItems.openSettings() }
            window.onBeginRecording = { [weak self] in
                guard let self else { return false }
                guard self.session == nil, !self.selecting else {
                    self.helpWindow?.showFeedback("请先结束当前截图", isError: true)
                    return false
                }
                self.recordingShortcut = true
                self.translationOverlay?.close()
                ShortcutAction.allCases.forEach { self.hotKeys.unregister($0.hotKeyID) }
                return true
            }
            window.onEndRecording = { [weak self] in
                guard let self else { return }
                self.recordingShortcut = false
                if !self.configureShortcuts(self.preferences.bindings, rollback: false) {
                    self.helpWindow?.showFeedback("快捷键被占用，请重新设置", isError: true)
                }
            }
            window.onShortcutChange = { [weak self] action, shortcut in
                guard let self else { return "设置未能保存" }
                let error = self.preferences.change(action, to: shortcut)
                self.refreshPermissionLabel()
                return error
            }
            window.onReset = { [weak self] in
                guard let self else { return "设置未能保存" }
                guard self.session == nil, !self.selecting else { return "请先结束当前截图" }
                let error = self.preferences.reset()
                self.refreshPermissionLabel()
                return error
            }
            helpWindow = window
        }
        refreshPermissionLabel()
        helpWindow?.updateLoginItem(loginItems.state)
        NSApp.activate(ignoringOtherApps: true)
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    private func refreshPermissionLabel() {
        helpWindow?.update(bindings: preferences.bindings, permissionGranted: CGPreflightScreenCaptureAccess())
        for action in ShortcutAction.allCases {
            let title = action == .scroll ? "滚动截图 / 完成" : action.title
            captureMenuItems[action]?.title = title + (preferences.bindings[action].map { "    " + $0.display } ?? "")
        }
    }

    @objc private func showShortcuts() {
        showHelp(); helpWindow?.revealSettings()
    }

    private func configureShortcuts(_ bindings: [ShortcutAction: Shortcut], rollback: Bool) -> Bool {
        ShortcutAction.allCases.forEach { hotKeys.unregister($0.hotKeyID) }
        func install(_ values: [ShortcutAction: Shortcut]) -> Bool {
            var success = true
            for action in ShortcutAction.allCases {
                guard let shortcut = values[action] else { continue }
                let registered = hotKeys.register(id: action.hotKeyID, key: shortcut.keyCode, modifiers: shortcut.modifiers) { [weak self] in
                    self?.performCapture(action)
                }
                if !registered { logger.error("Shortcut registration failed for action \(action.rawValue, privacy: .public)") }
                success = registered && success
            }
            return success
        }
        if install(bindings) { return true }
        if rollback {
            ShortcutAction.allCases.forEach { hotKeys.unregister($0.hotKeyID) }
            if !recordingShortcut { _ = install(preferences.bindings) }
        }
        return false
    }

    private func performCapture(_ action: ShortcutAction) {
        logger.notice("Capture requested: \(action.rawValue, privacy: .public)")
        switch action { case .copy: captureSingle(); case .scroll: captureLong(); case .translate: captureTranslate(); case .clipboard: showClipboard() }
    }

    @objc private func showClipboard() {
        guard session == nil, !selecting else { showToast("请先结束当前截图"); return }
        clipboardPaster.cancel()
        captureResult.close()
        if clipboardWindow?.isVisible == true { clipboardWindow?.cancelOperation(nil); return }
        helpWindow?.stopRecording(); rememberTarget()
        clipboardTarget = priorApplication.map { ClipboardPasteTarget(application: $0) }
        helpWindow?.orderOut(nil); translationWindow?.orderOut(nil); translationOverlay?.close()
        if clipboardWindow == nil {
            let window = ClipboardHistoryWindow(history: clipboardHistory)
            window.onAction = { [weak self] action in
                guard let self else { return }
                let target = self.clipboardTarget; self.clipboardTarget = nil
                if action == .copy {
                    target?.application.activate(options: []); self.showToast("已复制"); return
                }
                self.clipboardPaster.paste(to: target) { [weak self] outcome in
                    switch outcome {
                    case .sent: break
                    case .copiedOnly(let message): self?.showToast(message)
                    case .needsPermission: self?.showPastePermissionNeeded()
                    }
                }
            }
            window.onDismiss = { [weak self] in
                self?.clipboardPaster.cancel(); self?.clipboardTarget?.application.activate(options: [])
                self?.clipboardTarget = nil
            }
            clipboardWindow = window
        }
        clipboardWindow?.present(targetName: clipboardTarget?.name)
    }

    private func showPastePermissionNeeded() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "允许自动粘贴"
        alert.informativeText = "请在“辅助功能”中允许截图助手。内容已复制，授权前可按 ⌘V 手动粘贴。"
        alert.addButton(withTitle: "打开设置"); alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func installEditingMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let quit = NSMenuItem(title: "退出截图助手", action: #selector(quit), keyEquivalent: "q"); quit.target = self
        appMenu.addItem(quit); appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
        }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }

    @objc private func showTranslationSettings() {
        captureResult.close()
        helpWindow?.stopRecording()
        clipboardPaster.cancel(); clipboardWindow?.dismiss()
        if let window = translationSettingsWindow, window.isVisible {
            NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil); return
        }
        let window = TranslationSettingsWindow(store: translationStore)
        window.onSaved = { [weak self] in
            self?.translationWindow?.settingsChanged(); self?.translationOverlay?.settingsChanged()
        }
        translationSettingsWindow = window
        NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }

    private func translateImage(_ image: Raster) {
        if translationWindow == nil {
            let window = TranslationWindow(store: translationStore)
            window.onSettings = { [weak self] in self?.showTranslationSettings() }
            window.onRecapture = { [weak self] in self?.captureTranslate() }
            translationWindow = window
        }
        translationWindow?.begin(image)
    }

    private func translateInPlace(_ image: Raster, region: CaptureRegion) {
        if translationOverlay == nil {
            let overlay = TranslationOverlayController(store: translationStore)
            overlay.onSettings = { [weak self] in self?.showTranslationSettings() }
            overlay.onRecapture = { [weak self] in self?.captureTranslate() }
            overlay.onClose = { [weak self] in
                self?.hotKeys.unregister(CaptureHotKeyID.translationCancel)
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    self?.restoreTarget()
                }
            }
            translationOverlay = overlay
        }
        translationOverlay?.begin(image, region: region)
        let registered = hotKeys.register(id: CaptureHotKeyID.translationCancel, key: UInt32(kVK_Escape), modifiers: 0) { [weak self] in self?.translationOverlay?.close() }
        if !registered { logger.error("Overlay Escape shortcut registration failed") }
    }

    @objc func requestPermission() {
        if CGPreflightScreenCaptureAccess() {
            refreshPermissionLabel()
            showToast("截图权限已开启")
            return
        }
        _ = CGRequestScreenCaptureAccess()
        refreshPermissionLabel()
        if !CGPreflightScreenCaptureAccess() {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    private func ready() -> Bool {
        guard !selecting else { return false }
        if let window = translationSettingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil); showToast("请先保存或关闭翻译设置"); return false
        }
        guard CGPreflightScreenCaptureAccess() else {
            logger.notice("Capture blocked because screen permission is unavailable")
            showPermissionNeeded()
            return false
        }
        helpWindow?.stopRecording()
        clipboardPaster.cancel(); clipboardWindow?.dismiss()
        rememberTarget(); helpWindow?.orderOut(nil); translationWindow?.orderOut(nil)
        translationOverlay?.close()
        captureResult.close()
        return true
    }

    private func showPermissionNeeded() {
        guard !permissionAlertVisible else { return }
        permissionAlertVisible = true
        defer { permissionAlertVisible = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "需要开启截图权限"
        alert.informativeText = "请在系统设置的“录屏与系统录音”中允许截图助手。"
        alert.addButton(withTitle: "打开设置")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { requestPermission() }
    }

    private func rememberTarget() {
        if let app = NSWorkspace.shared.frontmostApplication,
           app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           app.bundleIdentifier != "com.apple.WindowManager" { priorApplication = app }
    }

    private func restoreTarget() {
        guard priorApplication?.bundleIdentifier != "com.apple.WindowManager" else { return }
        priorApplication?.activate(options: [])
    }

    @objc func captureSingle() {
        guard session == nil else { showToast("请先完成或取消当前滚动截图"); return }
        guard ready() else { return }
        let targetPID = priorApplication?.processIdentifier
        selecting = true
        selector.begin(scrolling: false) { [weak self] region in
            guard let self else { return }
            self.restoreTarget()
            guard let region else { self.selecting = false; return }
            Task {
                defer { self.selecting = false }
                do {
                    let source = try await CaptureSource(region: region, targetApplicationPID: targetPID)
                    defer { source.stop() }
                    let image = try await source.grab()
                    try ImageClipboard.copy(image)
                    self.captureResult.show(image, region: region, message: "已复制图片")
                } catch { self.showError(error.localizedDescription) }
            }
        }
    }

    @objc func captureTranslate() {
        guard session == nil else { showToast("请先完成或取消当前滚动截图"); return }
        guard ready() else { return }
        let targetPID = priorApplication?.processIdentifier
        selecting = true
        selector.begin(scrolling: false) { [weak self] region in
            guard let self else { return }
            self.restoreTarget()
            guard let region else { self.selecting = false; return }
            Task {
                defer { self.selecting = false }
                do {
                    let source = try await CaptureSource(region: region, targetApplicationPID: targetPID)
                    defer { source.stop() }
                    let image = try await source.grab()
                    self.translateInPlace(image, region: region)
                } catch { self.showError(error.localizedDescription) }
            }
        }
    }

    @objc func captureLong() {
        if let session { Task { await session.finish() }; return }
        guard ready() else { return }
        let targetPID = priorApplication?.processIdentifier
        selecting = true
        selector.begin(scrolling: true) { [weak self] region in
            guard let self else { return }
            self.selecting = false; self.restoreTarget()
            guard let region else { return }
            let capture = LongCapture(region: region, finishShortcut: self.preferences.bindings[.scroll]?.display,
                                      targetApplicationPID: targetPID)
            self.session = capture
            self.hotKeys.register(id: CaptureHotKeyID.scrollCancel, key: UInt32(kVK_Escape), modifiers: 0) { [weak capture] in capture?.cancel() }
            capture.onEnd = { [weak self] message in
                guard let self else { return }
                self.session = nil; self.hotKeys.unregister(CaptureHotKeyID.scrollCancel)
                if let message {
                    if message.hasPrefix("已复制") { self.showToast(message) }
                    else { self.showError(message) }
                }
            }
            capture.onTranslate = { [weak self] image in self?.translateImage(image) }
            capture.onCopied = { [weak self] image, message in
                self?.captureResult.show(image, region: region, message: message.components(separatedBy: " · ")[0])
            }
            Task { await capture.start() }
        }
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = "未能完成截图"
        alert.informativeText = message; alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private func showToast(_ message: String) {
        toast?.close()
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 390, height: 56),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true; panel.level = .floating
        let effect = FrostedSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 56), radius: 14)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center; label.frame = CGRect(x: 10, y: 17, width: 370, height: 22)
        effect.addSubview(label); panel.contentView = effect
        if let screen = NSScreen.main {
            panel.setFrameOrigin(CGPoint(x: screen.visibleFrame.midX - 195, y: screen.visibleFrame.minY + 60))
        }
        panel.orderFrontRegardless(); toast = panel
        Task { [weak self, weak panel] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            panel?.orderOut(nil); panel?.close()
            if self?.toast === panel { self?.toast = nil }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        captureResult.close()
        clipboardHistory.stop(); clipboardPaster.cancel()
        Task { await clipboardHistory.flush(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { clipboardHistory.stop() }
    @objc func quit() { captureResult.close(); clipboardHistory.stop(); clipboardPaster.cancel(); clipboardWindow?.close(); session?.cancel(); translationOverlay?.close(); translationWindow?.close(); translationSettingsWindow?.close(); NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
