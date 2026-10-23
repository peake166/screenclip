import AppKit
import ScreenCaptureKit
import CoreMedia
import OSLog

struct CaptureRegion {
    let screen: NSScreen
    let rect: CGRect
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
    private var windows: [NSWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var localKeyMonitor: Any?

    func begin(scrolling: Bool, completion: @escaping (CaptureRegion?) -> Void) {
        self.completion = completion
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless,
                                         backing: .buffered, defer: false, screen: screen)
            window.isOpaque = false; window.backgroundColor = .clear
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.scrolling = scrolling
            view.onComplete = { [weak self] rect in
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                self?.end(CaptureRegion(screen: screen, rect: global))
            }
            window.contentView = view
            windows.append(window)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.end(nil); return nil }
            return event
        }
    }

    private func end(_ region: CaptureRegion?) {
        guard let callback = completion else { return }
        completion = nil
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        callback(region)
    }
}

private final class SelectionWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class SelectionView: NSView {
    var scrolling = false
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
        NSColor.black.withAlphaComponent(0.25).setFill(); bounds.fill()
        if selection.width > 0 {
            NSColor.clear.setFill(); selection.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
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
        let effect = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 474, height: 104))
        effect.material = .hudWindow; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true; effect.layer?.cornerRadius = 13; effect.layer?.masksToBounds = true
        contentView = effect
        message.frame = CGRect(x: 16, y: 68, width: 442, height: 20)
        message.font = .systemFont(ofSize: 13, weight: .medium)
        progress.frame = CGRect(x: 16, y: 37, width: 190, height: 20)
        progress.textColor = .secondaryLabelColor; progress.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let hint = NSTextField(labelWithString: finishShortcut.map { $0 + " 完成 · Esc 取消" } ?? "Esc 取消")
        hint.frame = CGRect(x: 16, y: 10, width: 185, height: 18)
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
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
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        contentView = view
    }
}
