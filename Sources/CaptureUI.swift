import AppKit
import Carbon
import ScreenCaptureKit
import CoreMedia
import OSLog

struct CaptureRegion {
    let screen: NSScreen
    let rect: CGRect
}

struct CaptureSelection {
    let region: CaptureRegion
    let image: Raster?
}

@MainActor
final class CaptureSource {
    private var filter: SCContentFilter
    private let configuration: SCStreamConfiguration
    private var scrollFilter: SCContentFilter?
    private var targetBundleIdentifier: String?
    private var liveCapture: LiveCaptureStream?
    private var scrollFrames: ScopedScrollFrameSource?
    private let logger = Logger(subsystem: "com.local.screenclip", category: "CaptureSource")

    init(region: CaptureRegion, targetApplicationPID: Int32? = nil, scrolling: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let number = region.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == number.uint32Value })
        else { throw CaptureError.missingDisplay }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        if ownApps.isEmpty {
            // Some shareable-content snapshots omit our application while still
            // listing its floating capture controls and border windows.
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
        let config = SCStreamConfiguration()
        let bounds = region.screen.frame
        config.sourceRect = CGRect(x: region.rect.minX - bounds.minX,
                                   y: bounds.maxY - region.rect.maxY,
                                   width: region.rect.width, height: region.rect.height)
        let scale = region.screen.backingScaleFactor
        config.width = Int((region.rect.width * scale).rounded())
        config.height = Int((region.rect.height * scale).rounded())
        config.showsCursor = false
        config.capturesAudio = false
        config.colorSpaceName = CGColorSpace.sRGB
        configuration = config
        let selection = config.sourceRect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)
        let candidates = content.windows.filter {
            $0.owningApplication?.bundleIdentifier != "com.apple.WindowManager"
        }.map {
            CaptureWindowCandidate(id: $0.windowID, processID: $0.owningApplication?.processID ?? -1,
                frame: $0.frame, isOnScreen: $0.isOnScreen, layer: $0.windowLayer)
        }
        let metadata = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
            as? [[String: Any]] ?? []
        let order = metadata.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        let selectedProcessID = CaptureWindowSelection.targetProcessID(for: selection,
            preferredProcessID: targetApplicationPID, ownProcessID: ProcessInfo.processInfo.processIdentifier,
            windows: candidates, frontToBack: order)
        let target = content.applications.first { $0.processID == selectedProcessID }
        targetBundleIdentifier = target?.bundleIdentifier
        let containingWindowID = selectedProcessID.flatMap {
            CaptureWindowSelection.windowID(for: selection, processID: $0,
                                           windows: candidates, frontToBack: order)
        }
        if let target, target.bundleIdentifier == "com.netease.163music", containingWindowID != nil {
            // Keep the established Netease compatibility path scoped to its
            // containing window. Other applications retain display-region capture
            // with our own controls excluded, preserving normal window stacking.
            scrollFilter = SCContentFilter(display: display, including: [target], exceptingWindows: [])
        }
        logger.notice("Capture source configured; remembered pid: \(targetApplicationPID ?? 0); selected window pid: \(selectedProcessID ?? 0); display: \(display.displayID); excluded own applications: \(ownApps.count)")
        if !scrolling, let selectedProcessID, let target, target.bundleIdentifier == "com.tencent.xinWeChat" {
            let windowID = CaptureWindowSelection.windowID(for: selection, processID: selectedProcessID,
                                                           windows: candidates, frontToBack: order)
            let finalFilter: SCContentFilter
            if let windowID, let window = content.windows.first(where: { $0.windowID == windowID }) {
                finalFilter = SCContentFilter(display: display, including: [window])
            } else {
                // A selection crossing window edges keeps the full selected display area.
                finalFilter = filter
            }
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 3
            config.minimumFrameInterval = CMTime(value: 1, timescale: 6)
            let initial = SCContentFilter(display: display, including: [target], exceptingWindows: [])
            liveCapture = try await LiveCaptureStream(initialFilter: initial,
                finalFilter: finalFilter, configuration: config)
            logger.notice("Window compatibility session ready; target pid: \(selectedProcessID); window: \(windowID ?? 0); size: \(config.width)x\(config.height)")
        }
    }

    func beginScrollCapture() -> ScrollCaptureDiagnostics? {
        // Normal capture must keep working after the one-time diagnostic consent expires.
        if let scrollFilter {
            filter = scrollFilter
            logger.notice("Scrolling capture prepared with an application-only filter")
        } else {
            logger.notice("Scrolling capture prepared with a display filter")
        }
        return ScrollCaptureDiagnostics.beginIfRequested(bundleIdentifier: targetBundleIdentifier)
    }

    func startFrames(frameHandler: @escaping (CGImage) -> Void,
                     failureHandler: @escaping (String) -> Void) async throws {
        scrollFrames?.stop()
        let source = ScopedScrollFrameSource()
        scrollFrames = source
        try await source.start(filter: scrollFilter ?? filter, configuration: configuration,
                               frameHandler: frameHandler, failureHandler: failureHandler)
    }

    func grab() async throws -> Raster {
        if let liveCapture { return try await Raster(liveCapture.grab()) }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try Raster(image)
    }

    func stop() {
        scrollFrames?.stop(); scrollFrames = nil
        liveCapture?.stop(); liveCapture = nil
    }
}

@MainActor
final class SelectionController {
    private(set) var windows: [NSWindow] = []
    private var completion: ((Result<CaptureSelection?, Error>) -> Void)?
    private var localKeyMonitor: Any?
    private let screens: () -> [NSScreen]
    private let captureSnapshots: @MainActor ([NSScreen]) async throws -> [FrozenScreenFrame]
    private let presentWindows: Bool
    private let cancelKeys = HotKeys()
    private let preparationTimeout: TimeInterval
    private var preparation: Task<Void, Never>?
    private var deadline: DispatchWorkItem?
    private var generation = UUID()
    private var frozenScreens: [FrozenScreenFrame] = []

    init(screens: @escaping () -> [NSScreen] = { NSScreen.screens }, presentWindows: Bool = true,
         preparationTimeout: TimeInterval = 10,
         captureSnapshots: @escaping @MainActor ([NSScreen]) async throws -> [FrozenScreenFrame] = FrozenScreenCapture.capture) {
        self.screens = screens; self.presentWindows = presentWindows; self.captureSnapshots = captureSnapshots
        self.preparationTimeout = preparationTimeout
    }

    func begin(scrolling: Bool, completion: @escaping (Result<CaptureSelection?, Error>) -> Void) {
        if self.completion != nil { cancel() }
        self.completion = completion
        // Capture can start while another app still owns keyboard focus.
        // Reserve Escape before presenting any selection windows, then release it on completion.
        cancelKeys.register(id: CaptureHotKeyID.selectionCancel, key: UInt32(kVK_Escape), modifiers: 0) { [weak self] in
            self?.cancel()
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == kVK_Escape { self?.cancel(); return nil }
            return event
        }
        let available = screens()
        guard !available.isEmpty else { return }
        if scrolling {
            do { try present(available, snapshots: [], scrolling: true) }
            catch { end(.failure(error)) }
            return
        }
        // No selection window or app activation may precede this snapshot.
        let token = UUID(); generation = token
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token else { return }
                self.end(.failure(CaptureError.freezeTimeout))
            }
        }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.001, preparationTimeout), execute: timeout)
        let capture = captureSnapshots
        preparation = Task { [weak self] in
            do {
                let snapshots = try await capture(available)
                try Task.checkCancellation()
                guard let self, self.generation == token, self.completion != nil else { return }
                self.preparation = nil; self.deadline?.cancel(); self.deadline = nil
                let current = self.screens()
                guard Set(current.compactMap { FrozenScreenCapture.displayID($0) })
                        == Set(available.compactMap { FrozenScreenCapture.displayID($0) }) else { throw CaptureError.missingDisplay }
                try self.present(current, snapshots: snapshots, scrolling: false)
            } catch {
                guard let self, self.generation == token, self.completion != nil else { return }
                self.end(.failure(error))
            }
        }
    }

    private func present(_ screens: [NSScreen], snapshots: [FrozenScreenFrame], scrolling: Bool) throws {
        if !scrolling {
            for screen in screens {
                guard let id = FrozenScreenCapture.displayID(screen),
                      snapshots.contains(where: { $0.displayID == id && $0.screenFrame == screen.frame }) else { throw CaptureError.missingDisplay }
            }
        }
        frozenScreens = snapshots
        for screen in screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                         backing: .buffered, defer: false, screen: screen)
            window.isOpaque = !scrolling; window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.scrolling = scrolling
            view.frozenImage = snapshots.first { $0.displayID == FrozenScreenCapture.displayID(screen) }?.image
            view.onComplete = { [weak self] rect in
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self?.select(CaptureRegion(screen: screen, rect: global), scrolling: scrolling)
            }
            window.onCancel = { [weak self] in self?.cancel() }
            window.contentView = view
            window.initialFirstResponder = view
            window.makeFirstResponder(view)
            windows.append(window)
            if presentWindows { window.makeKeyAndOrderFront(nil) }
        }
        if presentWindows { NSApp.activate(ignoringOtherApps: true) }
    }

    func cancel() { end(.success(nil)) }

    private func select(_ region: CaptureRegion, scrolling: Bool) {
        guard completion != nil else { return }
        do {
            var image: Raster?
            if !scrolling {
                guard let id = FrozenScreenCapture.displayID(region.screen),
                      let frame = frozenScreens.first(where: { $0.displayID == id && $0.screenFrame == region.screen.frame }) else {
                    throw CaptureError.missingDisplay
                }
                image = try frame.crop(region.rect)
            }
            end(.success(CaptureSelection(region: region, image: image)))
        } catch { end(.failure(error)) }
    }

    private func end(_ result: Result<CaptureSelection?, Error>) {
        guard let callback = completion else { return }
        completion = nil
        generation = UUID(); preparation?.cancel(); preparation = nil
        deadline?.cancel(); deadline = nil
        cancelKeys.unregister(CaptureHotKeyID.selectionCancel)
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
        for window in windows {
            (window.contentView as? SelectionView)?.frozenImage = nil
            window.orderOut(nil); window.close()
        }
        windows.removeAll(); frozenScreens.removeAll()
        callback(result)
    }
}

private final class SelectionWindow: NSWindow {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == kVK_Escape { onCancel?() }
        else { super.keyDown(with: event) }
    }
}

final class SelectionView: NSView {
    var scrolling = false
    var frozenImage: CGImage? { didSet { needsDisplay = true } }
    var onComplete: ((CGRect) -> Void)?
    private var start: CGPoint?
    private var selection = CGRect.zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        selection = .zero; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let p = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                           width: abs(start.x - p.x), height: abs(start.y - p.y)).intersection(bounds).integral
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        if selection.width >= 12, selection.height >= (scrolling ? 120 : 12) { onComplete?(selection) }
        else { start = nil; selection = .zero; needsDisplay = true }
    }
    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool { drawSelection() }
    }
    private func drawSelection() {
        if let frozenImage { NSImage(cgImage: frozenImage, size: bounds.size).draw(in: bounds) }
        NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
        if selection.width > 0 {
            if let frozenImage {
                NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: selection).addClip()
                NSImage(cgImage: frozenImage, size: bounds.size).draw(in: bounds)
                NSGraphicsContext.restoreGraphicsState()
            } else { NSColor.clear.setFill(); selection.fill(using: .copy) }
            NSColor.screenClipAccent.setStroke()
            let path = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1.5; path.stroke()
        }
        let text = scrolling ? "框选要滚动的内容区域 · Esc 取消" : "框选截图区域，松开后复制 · Esc 取消"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let point = CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 86)
        let plate = CGRect(x: point.x - 18, y: point.y - 11, width: size.width + 36, height: size.height + 22)
        NSColor.black.withAlphaComponent(0.8).setFill(); NSBezierPath(roundedRect: plate, xRadius: 12, yRadius: 12).fill()
        (text as NSString).draw(at: point, withAttributes: attrs)
        if selection.width > 0 {
            let dimensions = "\(Int(selection.width)) × \(Int(selection.height))"
            let attr: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
            let sz = (dimensions as NSString).size(withAttributes: attr)
            let p = CGPoint(x: selection.minX + 7, y: max(8, selection.minY - 25))
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: CGRect(x: p.x - 5, y: p.y - 3, width: sz.width + 10, height: sz.height + 6), xRadius: 4, yRadius: 4).fill()
            (dimensions as NSString).draw(at: p, withAttributes: attr)
        }
    }
}

@MainActor
final class ScrollPanel: NSPanel {
    let message = NSTextField(labelWithString: "准备截图…")
    let progress = NSTextField(labelWithString: "")
    let finishButton = NSButton(title: "复制长图", target: nil, action: nil)
    let translateButton = NSButton(title: "翻译长图", target: nil, action: nil)
    var onFinish: (() -> Void)?
    var onTranslate: (() -> Void)?
    var onCancel: (() -> Void)?

    init(region: CaptureRegion, finishShortcut: String? = "⌃⌥⌘5") {
        let available = region.screen.visibleFrame
        var origin = CGPoint(x: min(max(region.rect.minX, available.minX + 8), available.maxX - 482),
                             y: region.rect.maxY + 10)
        if origin.y + 104 > available.maxY { origin.y = max(available.minY + 10, region.rect.minY - 114) }
        super.init(contentRect: CGRect(origin: origin, size: CGSize(width: 474, height: 104)),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        title = "滚动截图"
        hidesOnDeactivate = false
        level = .floating; isOpaque = false; backgroundColor = .clear
        hasShadow = true; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let effect = FrostedSurface(frame: CGRect(x: 0, y: 0, width: 474, height: 104), radius: 14)
        contentView = effect
        message.frame = CGRect(x: 16, y: 68, width: 442, height: 20)
        message.font = .systemFont(ofSize: 13, weight: .medium)
        progress.frame = CGRect(x: 16, y: 37, width: 190, height: 20)
        progress.textColor = .screenClipSecondaryLabel; progress.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let hint = NSTextField(labelWithString: finishShortcut.map { $0 + " 完成 · Esc 取消" } ?? "Esc 取消")
        hint.frame = CGRect(x: 16, y: 10, width: 185, height: 18)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .screenClipSecondaryLabel
        finishButton.target = self; finishButton.action = #selector(finish)
        finishButton.bezelStyle = .rounded
        finishButton.frame = CGRect(x: 360, y: 14, width: 102, height: 32)
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelCapture))
        cancel.bezelStyle = .rounded; cancel.frame = CGRect(x: 204, y: 14, width: 64, height: 32)
        translateButton.target = self; translateButton.action = #selector(translateCapture)
        translateButton.bezelStyle = .rounded; translateButton.frame = CGRect(x: 270, y: 14, width: 88, height: 32)
        [message, progress, hint, finishButton, cancel, translateButton].forEach { effect.addSubview($0) }
    }
    @objc private func finish() { onFinish?() }
    @objc private func cancelCapture() { onCancel?() }
    @objc private func translateCapture() { onTranslate?() }
}

@MainActor
final class RegionBorder: NSWindow {
    init(region: CaptureRegion) {
        super.init(contentRect: region.rect.insetBy(dx: -2, dy: -2), styleMask: .borderless, backing: .buffered, defer: false)
        title = "截图区域"
        level = .floating; isOpaque = false; backgroundColor = .clear
        ignoresMouseEvents = true; isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true; view.layer?.borderWidth = 2
        view.layer?.borderColor = NSColor.screenClipAccent.cgColor
        contentView = view
    }
}
