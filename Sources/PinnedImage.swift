import AppKit
import Carbon
import CoreGraphics
import ImageIO
import OSLog
import UniformTypeIdentifiers

enum PinnedImageError: LocalizedError {
    case noClipboardImage
    case unreadableFile(String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .noClipboardImage: return "剪贴板中没有图片。"
        case .unreadableFile(let name): return "无法打开图片“\(name)”。"
        case .invalidImage: return "无法读取图片内容。"
        }
    }
}

enum PinnedImageLayout {
    static let minimumEdge: CGFloat = 48
    static let minimumScale: CGFloat = 0.15
    static let maximumScale: CGFloat = 6.0
    static let minimumOpacity: CGFloat = 0.20
    static let maximumOpacity: CGFloat = 1.0
    static let screenMargin: CGFloat = 12
    static let cascadeStep: CGFloat = 24
    static let minimumVisibleOverlap: CGFloat = 44

    static func naturalSize(pixelWidth: Int, pixelHeight: Int, backingScale: CGFloat) -> CGSize {
        let scale = max(1, backingScale)
        return CGSize(
            width: max(1, (CGFloat(pixelWidth) / scale).rounded()),
            height: max(1, (CGFloat(pixelHeight) / scale).rounded())
        )
    }

    static func effectiveMinimumScale(for naturalSize: CGSize) -> CGFloat {
        let longest = max(1, max(naturalSize.width, naturalSize.height))
        return min(1.0, max(minimumScale, minimumEdge / longest))
    }

    static func clampedScale(_ value: CGFloat, naturalSize: CGSize) -> CGFloat {
        min(maximumScale, max(effectiveMinimumScale(for: naturalSize), value))
    }

    static func clampedOpacity(_ value: CGFloat) -> CGFloat {
        min(maximumOpacity, max(minimumOpacity, value))
    }

    static func initialFrame(
        naturalSize: CGSize,
        anchorRect: CGRect?,
        visibleFrame: CGRect,
        cascadeIndex: Int = 0
    ) -> (frame: CGRect, scale: CGFloat) {
        let safeWidth = max(minimumEdge, visibleFrame.width - screenMargin * 2)
        let safeHeight = max(minimumEdge, visibleFrame.height - screenMargin * 2)
        let maxWidth = anchorRect == nil ? min(safeWidth, visibleFrame.width * 0.80) : safeWidth
        let maxHeight = anchorRect == nil ? min(safeHeight, visibleFrame.height * 0.80) : safeHeight
        let fitScale = min(1.0, maxWidth / max(1, naturalSize.width), maxHeight / max(1, naturalSize.height))
        let scale = clampedScale(fitScale, naturalSize: naturalSize)
        let width = min(safeWidth, max(20, (naturalSize.width * scale).rounded()))
        let height = min(safeHeight, max(20, (naturalSize.height * scale).rounded()))
        let size = CGSize(width: width, height: height)

        var origin: CGPoint
        if let anchorRect {
            if abs(scale - 1.0) < 0.001,
               abs(anchorRect.width - size.width) <= 2,
               abs(anchorRect.height - size.height) <= 2 {
                origin = anchorRect.origin
            } else {
                origin = CGPoint(
                    x: (anchorRect.midX - size.width / 2).rounded(),
                    y: (anchorRect.midY - size.height / 2).rounded()
                )
            }
        } else {
            let step = CGFloat(max(0, cascadeIndex) % 8) * cascadeStep
            origin = CGPoint(
                x: (visibleFrame.midX - size.width / 2 + step).rounded(),
                y: (visibleFrame.midY - size.height / 2 - step).rounded()
            )
        }

        let minX = visibleFrame.minX + screenMargin
        let maxX = max(minX, visibleFrame.maxX - screenMargin - size.width)
        let minY = visibleFrame.minY + screenMargin
        let maxY = max(minY, visibleFrame.maxY - screenMargin - size.height)
        origin.x = min(maxX, max(minX, origin.x))
        origin.y = min(maxY, max(minY, origin.y))
        return (CGRect(origin: origin, size: size), scale)
    }

    static func scaledFrame(
        currentFrame: CGRect,
        naturalSize: CGSize,
        targetScale: CGFloat,
        anchorInWindow: CGPoint?,
        visibleFrame: CGRect?
    ) -> (frame: CGRect, scale: CGFloat) {
        let scale = clampedScale(targetScale, naturalSize: naturalSize)
        let newSize = CGSize(
            width: max(20, (naturalSize.width * scale).rounded()),
            height: max(20, (naturalSize.height * scale).rounded())
        )
        let anchor = anchorInWindow ?? CGPoint(x: currentFrame.width / 2, y: currentFrame.height / 2)
        let rx = anchor.x / max(1, currentFrame.width)
        let ry = anchor.y / max(1, currentFrame.height)
        let screenAnchorX = currentFrame.minX + anchor.x
        let screenAnchorY = currentFrame.minY + anchor.y
        var origin = CGPoint(
            x: (screenAnchorX - rx * newSize.width).rounded(),
            y: (screenAnchorY - ry * newSize.height).rounded()
        )
        if let visibleFrame {
            origin = clampPartiallyVisible(origin: origin, size: newSize, visibleFrame: visibleFrame)
        }
        return (CGRect(origin: origin, size: newSize), scale)
    }

    static func resizedFrame(
        currentFrame: CGRect,
        naturalSize: CGSize,
        targetWidth: CGFloat,
        visibleFrame: CGRect?
    ) -> (frame: CGRect, scale: CGFloat) {
        let targetScale = targetWidth / max(1, naturalSize.width)
        let topLeftAnchor = CGPoint(x: 0, y: currentFrame.height)
        return scaledFrame(
            currentFrame: currentFrame,
            naturalSize: naturalSize,
            targetScale: targetScale,
            anchorInWindow: topLeftAnchor,
            visibleFrame: visibleFrame
        )
    }

    static func clampPartiallyVisible(origin: CGPoint, size: CGSize, visibleFrame: CGRect) -> CGPoint {
        let keep = min(minimumVisibleOverlap, min(size.width, size.height))
        let minX = visibleFrame.minX - size.width + keep
        let maxX = visibleFrame.maxX - keep
        let minY = visibleFrame.minY - size.height + keep
        let maxY = visibleFrame.maxY - keep
        return CGPoint(
            x: min(maxX, max(minX, origin.x)),
            y: min(maxY, max(minY, origin.y))
        )
    }
}

enum PinnedImageLoader {
    static let maximumPixels = 36_000_000

    static func load(data: Data) throws -> Raster {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw PinnedImageError.invalidImage }
        return try decode(source)
    }

    static func load(url: URL) throws -> Raster {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw PinnedImageError.unreadableFile(url.lastPathComponent) }
        do {
            return try decode(source)
        } catch {
            throw PinnedImageError.unreadableFile(url.lastPathComponent)
        }
    }

    static func loadFromPasteboard(_ board: NSPasteboard = .general) throws -> Raster {
        if let items = board.pasteboardItems {
            for item in items {
                if let png = item.data(forType: .png), let raster = try? load(data: png) { return raster }
                if let tiff = item.data(forType: .tiff), let raster = try? load(data: tiff) { return raster }
            }
            for item in items {
                guard let raw = item.string(forType: .fileURL),
                      let url = URL(string: raw),
                      url.isFileURL else { continue }
                if isImageURL(url), let raster = try? load(url: url) { return raster }
            }
        }
        if let png = board.data(forType: .png), let raster = try? load(data: png) { return raster }
        if let tiff = board.data(forType: .tiff), let raster = try? load(data: tiff) { return raster }
        throw PinnedImageError.noClipboardImage
    }

    static func isImageURL(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let type = values.contentType {
            return type.conforms(to: .image)
        }
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .image)
        }
        return false
    }

    private static func decode(_ source: CGImageSource) throws -> Raster {
        try autoreleasepool {
            guard CGImageSourceGetCount(source) > 0 else { throw PinnedImageError.invalidImage }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let pixelWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
            let pixelHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let pixels = pixelWidth > 0 && pixelHeight > 0 ? Int64(pixelWidth) * Int64(pixelHeight) : 0
            let cgImage: CGImage?
            if pixels > Int64(maximumPixels) {
                let ratio = sqrt(Double(maximumPixels) / Double(pixels))
                let maxEdge = max(64, Int((Double(max(pixelWidth, pixelHeight)) * ratio).rounded(.down)))
                cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxEdge,
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else if orientation != 1, pixelWidth > 0, pixelHeight > 0 {
                cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(pixelWidth, pixelHeight),
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            } else {
                cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                ] as CFDictionary)
            }
            guard let cgImage, cgImage.width > 0, cgImage.height > 0 else { throw PinnedImageError.invalidImage }
            return try Raster(cgImage)
        }
    }
}

@MainActor
private final class PinnedImageSurfaceView: NSView {
    var cgImage: CGImage? { didSet { needsDisplay = true } }
    var isHovered = false { didSet { updateChrome() } }
    var isActiveKey = false { didSet { needsDisplay = true } }
    var onClose: (() -> Void)?
    var onResetScale: (() -> Void)?
    var onScrollZoom: ((CGFloat, CGPoint) -> Void)?
    var onPinchZoom: ((CGFloat, CGPoint) -> Void)?
    var onOpacityDelta: ((CGFloat) -> Void)?
    var onResizeDrag: ((CGFloat) -> Void)?
    var onBuildContextMenu: (() -> NSMenu)?

    private var tracking: NSTrackingArea?
    private let closeButton = NSButton()
    private let hudContainer = NSView()
    private let hudLabel = NSTextField(labelWithString: "")
    private var hudDismissal: DispatchWorkItem?
    private var dragOriginMouse: CGPoint?
    private var dragOriginWindow: CGPoint?
    private var resizeOriginMouse: CGPoint?
    private var resizeOriginWidth: CGFloat?

    private static let cornerRadius: CGFloat = 6
    private static let resizeHandleSize: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.masksToBounds = true

        closeButton.bezelStyle = .regularSquare
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 11
        closeButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭贴图")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        closeButton.contentTintColor = .white
        closeButton.toolTip = "关闭贴图（Esc）"
        closeButton.setAccessibilityLabel("关闭贴图")
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        addSubview(closeButton)

        hudContainer.wantsLayer = true
        hudContainer.layer?.cornerRadius = 11
        hudContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        hudContainer.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.isHidden = true
        hudLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        hudLabel.textColor = .white
        hudLabel.lineBreakMode = .byTruncatingTail
        hudLabel.translatesAutoresizingMaskIntoConstraints = false
        hudContainer.addSubview(hudLabel)
        addSubview(hudContainer)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 22),
            closeButton.heightAnchor.constraint(equalToConstant: 22),

            hudLabel.leadingAnchor.constraint(equalTo: hudContainer.leadingAnchor, constant: 9),
            hudLabel.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor, constant: -9),
            hudLabel.topAnchor.constraint(equalTo: hudContainer.topAnchor, constant: 4),
            hudLabel.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor, constant: -4),
            hudContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hudContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            hudContainer.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func showHUD(_ message: String, duration: TimeInterval = 1.2) {
        hudDismissal?.cancel()
        hudLabel.stringValue = message
        hudContainer.isHidden = false
        guard duration > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hudContainer.isHidden = true }
        }
        hudDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func cleanup() {
        hudDismissal?.cancel(); hudDismissal = nil
        if let tracking { removeTrackingArea(tracking); self.tracking = nil }
        cgImage = nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.arrow.set()
    }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isInResizeHandle(point) { NSCursor.crosshair.set() }
        else { NSCursor.openHand.set() }
    }

    private func updateChrome() {
        let compact = bounds.width < 56 || bounds.height < 44
        closeButton.isHidden = !isHovered || compact
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        updateChrome()
    }

    private func isInResizeHandle(_ point: CGPoint) -> Bool {
        bounds.width >= 56 && bounds.height >= 44
            && point.x >= bounds.maxX - Self.resizeHandleSize
            && point.y <= Self.resizeHandleSize
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if !closeButton.isHidden, closeButton.frame.contains(point) { return }
        if event.clickCount == 2 {
            onResetScale?()
            return
        }
        if isInResizeHandle(point) {
            resizeOriginMouse = NSEvent.mouseLocation
            resizeOriginWidth = window?.frame.width ?? bounds.width
            dragOriginMouse = nil; dragOriginWindow = nil
            return
        }
        resizeOriginMouse = nil; resizeOriginWidth = nil
        dragOriginMouse = NSEvent.mouseLocation
        dragOriginWindow = window?.frame.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let current = NSEvent.mouseLocation
        if let start = resizeOriginMouse, let baseWidth = resizeOriginWidth {
            let delta = (current.x - start.x) - (current.y - start.y) * 0.5
            onResizeDrag?(max(24, baseWidth + delta))
            return
        }
        guard let start = dragOriginMouse, let origin = dragOriginWindow, let window else { return }
        window.setFrameOrigin(CGPoint(
            x: (origin.x + current.x - start.x).rounded(),
            y: (origin.y + current.y - start.y).rounded()
        ))
    }

    override func mouseUp(with event: NSEvent) {
        dragOriginMouse = nil; dragOriginWindow = nil
        resizeOriginMouse = nil; resizeOriginWidth = nil
        if isHovered { NSCursor.openHand.set() }
    }

    override func scrollWheel(with event: NSEvent) {
        let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.012 : event.scrollingDeltaY * 0.08
        guard abs(rawDelta) > 0.0001 else { return }
        if event.modifierFlags.contains(.option) {
            onOpacityDelta?(rawDelta * 0.5)
        } else {
            let point = convert(event.locationInWindow, from: nil)
            onScrollZoom?(exp(rawDelta), point)
        }
    }

    override func magnify(with event: NSEvent) {
        guard abs(event.magnification) > 0.0001 else { return }
        let point = convert(event.locationInWindow, from: nil)
        onPinchZoom?(1 + event.magnification, point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        onBuildContextMenu?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        autoreleasepool {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let clip = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            clip.addClip()

            NSColor.windowBackgroundColor.setFill()
            bounds.fill()

            if let cgImage {
                context.interpolationQuality = .high
                context.draw(cgImage, in: bounds)
            }

            let borderColor: NSColor
            if isHovered || isActiveKey {
                borderColor = NSColor.screenClipAccent.withAlphaComponent(isHovered ? 0.72 : 0.45)
            } else {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                borderColor = dark
                    ? NSColor.white.withAlphaComponent(0.22)
                    : NSColor.black.withAlphaComponent(0.18)
            }
            borderColor.setStroke()
            let stroke = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                xRadius: Self.cornerRadius,
                yRadius: Self.cornerRadius
            )
            stroke.lineWidth = isHovered ? 1.5 : 1.0
            stroke.stroke()

            if isHovered, bounds.width >= 56, bounds.height >= 44 {
                let grip = NSBezierPath()
                grip.lineWidth = 1.4
                grip.lineCapStyle = .round
                NSColor.black.withAlphaComponent(0.45).setStroke()
                for offset in [CGFloat(5), CGFloat(9)] {
                    grip.move(to: CGPoint(x: bounds.maxX - offset - 3, y: 4))
                    grip.line(to: CGPoint(x: bounds.maxX - 4, y: offset + 3))
                }
                grip.stroke()
                let lightGrip = NSBezierPath()
                lightGrip.lineWidth = 1.0
                lightGrip.lineCapStyle = .round
                NSColor.white.withAlphaComponent(0.85).setStroke()
                for offset in [CGFloat(5), CGFloat(9)] {
                    lightGrip.move(to: CGPoint(x: bounds.maxX - offset - 3.5, y: 4.5))
                    lightGrip.line(to: CGPoint(x: bounds.maxX - 4.5, y: offset + 3.5))
                }
                lightGrip.stroke()
            }
        }
    }

    @objc private func closePressed() { onClose?() }
}

@MainActor
final class PinnedImagePanel: NSPanel, NSWindowDelegate {
    let pinID = UUID()
    let naturalSize: CGSize
    private(set) var scaleFactor: CGFloat
    private(set) var imageOpacity: CGFloat = 1.0
    private(set) var sticksToAllSpaces: Bool = true
    private(set) var isClosed = false
    private(set) var raster: Raster?
    var displayedImage: CGImage? { surface.cgImage }
    func setHoverStateForPreview(_ hovered: Bool, hud: String? = nil) {
        surface.isHovered = hovered
        if let hud { surface.showHUD(hud, duration: 0) }
    }

    var onCloseRequested: ((PinnedImagePanel) -> Void)?
    var onCloseAllRequested: (() -> Void)?
    var onToggleHideAllRequested: (() -> Void)?
    var onTranslateRequested: ((Raster) -> Void)?
    var onStatusMessage: ((String) -> Void)?
    var siblingCountProvider: (() -> Int)?

    private let board: NSPasteboard
    private let recognize: (Raster) async throws -> String
    private let surface: PinnedImageSurfaceView
    private var ocrTask: Task<Void, Never>?

    init(
        image: Raster,
        naturalSize: CGSize,
        initialFrame: CGRect,
        initialScale: CGFloat,
        pasteboard: NSPasteboard = .general,
        recognize: @escaping (Raster) async throws -> String = {
            try await TextRecognizer.recognizeDocument($0, maximumCharacters: nil).text
        }
    ) throws {
        let cg = try image.cgImage()
        self.raster = image
        self.naturalSize = naturalSize
        self.scaleFactor = initialScale
        self.board = pasteboard
        self.recognize = recognize
        self.surface = PinnedImageSurfaceView(frame: CGRect(origin: .zero, size: initialFrame.size))

        super.init(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "屏幕贴图"
        delegate = self
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        surface.cgImage = cg
        surface.autoresizingMask = [.width, .height]
        surface.onClose = { [weak self] in self?.requestClose() }
        surface.onResetScale = { [weak self] in self?.resetScale() }
        surface.onScrollZoom = { [weak self] factor, point in self?.scale(by: factor, anchorInWindow: point) }
        surface.onPinchZoom = { [weak self] factor, point in self?.scale(by: factor, anchorInWindow: point) }
        surface.onOpacityDelta = { [weak self] delta in
            guard let self else { return }
            self.setOpacity(self.imageOpacity + delta)
        }
        surface.onResizeDrag = { [weak self] targetWidth in self?.resize(toWidth: targetWidth) }
        surface.onBuildContextMenu = { [weak self] in self?.buildContextMenu() ?? NSMenu() }
        contentView = surface
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func windowDidBecomeKey(_ notification: Notification) { surface.isActiveKey = true }
    func windowDidResignKey(_ notification: Notification) { surface.isActiveKey = false }
    func windowWillClose(_ notification: Notification) {
        if !isClosed { requestClose() }
    }

    override func cancelOperation(_ sender: Any?) { requestClose() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) { requestClose(); return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": requestClose(); return true
            case "c": copyImageToPasteboard(); return true
            case "s": saveImageAsPNG(); return true
            case "0": resetScale(); return true
            case "=", "+": zoomIn(); return true
            case "-": zoomOut(); return true
            default: break
            }
        }
        if event.keyCode == UInt16(kVK_Escape) { requestClose(); return true }
        return super.performKeyEquivalent(with: event)
    }

    func scale(by multiplier: CGFloat, anchorInWindow: CGPoint? = nil) {
        applyScale(scaleFactor * multiplier, anchorInWindow: anchorInWindow)
    }

    func applyScale(_ target: CGFloat, anchorInWindow: CGPoint? = nil, showFeedback: Bool = true) {
        guard !isClosed else { return }
        let updated = PinnedImageLayout.scaledFrame(
            currentFrame: frame,
            naturalSize: naturalSize,
            targetScale: target,
            anchorInWindow: anchorInWindow,
            visibleFrame: (screen ?? NSScreen.main)?.visibleFrame
        )
        scaleFactor = updated.scale
        setFrame(updated.frame, display: true)
        if showFeedback {
            surface.showHUD("\(Int((scaleFactor * 100).rounded()))%")
        }
    }

    func resize(toWidth width: CGFloat) {
        guard !isClosed else { return }
        let updated = PinnedImageLayout.resizedFrame(
            currentFrame: frame,
            naturalSize: naturalSize,
            targetWidth: width,
            visibleFrame: (screen ?? NSScreen.main)?.visibleFrame
        )
        scaleFactor = updated.scale
        setFrame(updated.frame, display: true)
        surface.showHUD("\(Int((scaleFactor * 100).rounded()))%")
    }

    @objc func resetScale() { applyScale(1.0) }
    @objc func zoomIn() { scale(by: 1.15) }
    @objc func zoomOut() { scale(by: 1.0 / 1.15) }

    func setOpacity(_ value: CGFloat, showFeedback: Bool = true) {
        guard !isClosed else { return }
        imageOpacity = PinnedImageLayout.clampedOpacity(value)
        alphaValue = imageOpacity
        if showFeedback {
            surface.showHUD("透明度 \(Int((imageOpacity * 100).rounded()))%")
        }
    }

    func setSticksToAllSpaces(_ enabled: Bool) {
        guard !isClosed else { return }
        sticksToAllSpaces = enabled
        collectionBehavior = enabled
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    @objc func toggleSticksToAllSpaces() {
        setSticksToAllSpaces(!sticksToAllSpaces)
        surface.showHUD(sticksToAllSpaces ? "已设为所有桌面显示" : "仅当前桌面显示")
    }

    @objc func copyImageToPasteboard() {
        guard let raster else { return }
        do {
            try ImageClipboard.copy(raster, to: board)
            surface.showHUD("已复制图片")
        } catch {
            surface.showHUD("复制失败")
        }
    }

    @objc func copyRecognizedText() {
        guard let raster, ocrTask == nil else { return }
        surface.showHUD("正在识别文字…", duration: 0)
        let recognize = self.recognize
        let board = self.board
        ocrTask = Task { [weak self] in
            defer { self?.ocrTask = nil }
            do {
                let text = try await recognize(raster).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard let self, !self.isClosed else { return }
                guard !text.isEmpty else {
                    self.surface.showHUD("未识别到文字", duration: 1.8)
                    return
                }
                board.clearContents()
                if board.setString(text, forType: .string) {
                    self.surface.showHUD("已复制文字", duration: 1.6)
                } else {
                    self.surface.showHUD("复制文字失败", duration: 1.8)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, !self.isClosed else { return }
                self.surface.showHUD("识别失败", duration: 1.8)
            }
        }
    }

    @objc func translatePinnedImage() {
        guard let raster else { return }
        onTranslateRequested?(raster)
    }

    @objc func saveImageAsPNG() {
        guard let raster else { return }
        let savePanel = NSSavePanel()
        savePanel.title = "保存贴图"
        savePanel.prompt = "保存"
        savePanel.allowedContentTypes = [.png]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        savePanel.nameFieldStringValue = "ScreenClip-\(formatter.string(from: Date())).png"
        NSApp.activate(ignoringOtherApps: true)
        guard savePanel.runModal() == .OK, let destination = savePanel.url else { return }
        do {
            try raster.png().write(to: destination, options: .atomic)
            surface.showHUD("已保存")
        } catch {
            onStatusMessage?("保存失败：\(error.localizedDescription)")
        }
    }

    @objc private func applyOpacityPreset(_ sender: NSMenuItem) {
        setOpacity(CGFloat(sender.tag) / 100.0)
    }

    @objc private func requestHideAll() { onToggleHideAllRequested?() }
    @objc private func requestCloseAll() { onCloseAllRequested?() }
    @objc func requestClose() {
        if let onCloseRequested { onCloseRequested(self) }
        else { releaseAndClose() }
    }

    func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, key: String = "", tag: Int = 0, state: NSControl.StateValue = .off, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.tag = tag
            item.state = state
            item.isEnabled = enabled
            menu.addItem(item)
            return item
        }
        _ = add("复制图片", #selector(copyImageToPasteboard), key: "c")
        _ = add("复制图中文字", #selector(copyRecognizedText), enabled: ocrTask == nil)
        if onTranslateRequested != nil {
            _ = add("翻译此图", #selector(translatePinnedImage))
        }
        _ = add("另存为 PNG…", #selector(saveImageAsPNG), key: "s")
        menu.addItem(.separator())
        _ = add("恢复原始大小 (100%)", #selector(resetScale), key: "0", enabled: abs(scaleFactor - 1.0) > 0.01)

        let opacityItem = NSMenuItem(title: "透明度", action: nil, keyEquivalent: "")
        let opacityMenu = NSMenu()
        let currentPercent = Int((imageOpacity * 100).rounded())
        for percent in [100, 85, 70, 50, 30] {
            let option = NSMenuItem(title: "\(percent)%", action: #selector(applyOpacityPreset(_:)), keyEquivalent: "")
            option.target = self
            option.tag = percent
            option.state = abs(currentPercent - percent) <= 4 ? .on : .off
            opacityMenu.addItem(option)
        }
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        _ = add("所有桌面显示", #selector(toggleSticksToAllSpaces), state: sticksToAllSpaces ? .on : .off)
        menu.addItem(.separator())
        if onToggleHideAllRequested != nil {
            _ = add("隐藏全部贴图", #selector(requestHideAll))
        }
        _ = add("关闭此贴图", #selector(requestClose), key: "w")
        let total = siblingCountProvider?() ?? 1
        if total > 1, onCloseAllRequested != nil {
            _ = add("关闭全部贴图 (\(total))", #selector(requestCloseAll))
        }
        return menu
    }

    func releaseAndClose() {
        guard !isClosed else { return }
        isClosed = true
        ocrTask?.cancel(); ocrTask = nil
        delegate = nil
        surface.cleanup()
        raster = nil
        orderOut(nil)
        close()
    }
}

@MainActor
final class PinnedImageManager {
    private(set) var panels: [PinnedImagePanel] = []
    private(set) var areHidden = false
    private var cascadeCursor = 0
    private let logger = Logger(subsystem: "com.local.screenclip", category: "PinnedImage")
    private let board: NSPasteboard
    private let recognize: (Raster) async throws -> String

    var count: Int { panels.count }
    var onChange: (() -> Void)?
    var onTranslate: ((Raster) -> Void)?
    var onNotify: ((String) -> Void)?

    init(
        pasteboard: NSPasteboard = .general,
        recognize: @escaping (Raster) async throws -> String = {
            try await TextRecognizer.recognizeDocument($0, maximumCharacters: nil).text
        }
    ) {
        self.board = pasteboard
        self.recognize = recognize
    }

    @discardableResult
    func pin(
        _ image: Raster,
        region: CaptureRegion? = nil,
        screen: NSScreen? = nil,
        present: Bool = true
    ) throws -> PinnedImagePanel {
        guard let targetScreen = region?.screen ?? screen ?? NSScreen.main ?? NSScreen.screens.first else {
            throw CaptureError.missingDisplay
        }
        let naturalFromPixels = PinnedImageLayout.naturalSize(
            pixelWidth: image.width,
            pixelHeight: image.height,
            backingScale: targetScreen.backingScaleFactor
        )
        let natural: CGSize
        if let region {
            let regionSize = CGSize(width: max(1, region.rect.width.rounded()), height: max(1, region.rect.height.rounded()))
            let matchesRegion = abs(naturalFromPixels.width - regionSize.width) <= 2
                && abs(naturalFromPixels.height - regionSize.height) <= 2
            natural = matchesRegion ? regionSize : naturalFromPixels
        } else {
            natural = naturalFromPixels
        }
        let cascadeIndex = region == nil ? cascadeCursor : 0
        if region == nil { cascadeCursor += 1 }
        let placement = PinnedImageLayout.initialFrame(
            naturalSize: natural,
            anchorRect: region?.rect,
            visibleFrame: targetScreen.visibleFrame,
            cascadeIndex: cascadeIndex
        )
        let panel = try PinnedImagePanel(
            image: image,
            naturalSize: natural,
            initialFrame: placement.frame,
            initialScale: placement.scale,
            pasteboard: board,
            recognize: recognize
        )
        panel.siblingCountProvider = { [weak self] in self?.panels.count ?? 1 }
        panel.onCloseRequested = { [weak self] target in self?.close(target) }
        panel.onCloseAllRequested = { [weak self] in self?.closeAll() }
        panel.onToggleHideAllRequested = { [weak self] in self?.toggleHideAll() }
        panel.onTranslateRequested = { [weak self] raster in self?.onTranslate?(raster) }
        panel.onStatusMessage = { [weak self] message in self?.onNotify?(message) }

        if areHidden {
            areHidden = false
            if present { panels.forEach { $0.orderFrontRegardless() } }
        }
        panels.append(panel)
        if present { panel.orderFrontRegardless() }
        logger.notice("Pinned image \(image.width)x\(image.height); active count: \(self.panels.count)")
        onChange?()
        return panel
    }

    @discardableResult
    func pinFromData(_ data: Data, screen: NSScreen? = nil, present: Bool = true) throws -> PinnedImagePanel {
        let image = try PinnedImageLoader.load(data: data)
        return try pin(image, region: nil, screen: screen, present: present)
    }

    @discardableResult
    func pinFromURL(_ url: URL, screen: NSScreen? = nil, present: Bool = true) throws -> PinnedImagePanel {
        let image = try PinnedImageLoader.load(url: url)
        return try pin(image, region: nil, screen: screen, present: present)
    }

    @discardableResult
    func pinFromPasteboard(_ board: NSPasteboard? = nil, screen: NSScreen? = nil, present: Bool = true) throws -> PinnedImagePanel {
        let image = try PinnedImageLoader.loadFromPasteboard(board ?? self.board)
        return try pin(image, region: nil, screen: screen, present: present)
    }

    func setAllHidden(_ hidden: Bool, present: Bool = true) {
        guard !panels.isEmpty, areHidden != hidden else { return }
        areHidden = hidden
        if hidden {
            panels.forEach { $0.orderOut(nil) }
        } else if present {
            panels.forEach { $0.orderFrontRegardless() }
        }
        onChange?()
    }

    func toggleHideAll(present: Bool = true) {
        setAllHidden(!areHidden, present: present)
    }

    func close(_ panel: PinnedImagePanel) {
        panels.removeAll { $0 === panel }
        panel.releaseAndClose()
        if panels.isEmpty {
            areHidden = false
            cascadeCursor = 0
        }
        onChange?()
    }

    func closeAll() {
        let existing = panels
        panels.removeAll()
        areHidden = false
        cascadeCursor = 0
        existing.forEach { $0.releaseAndClose() }
        onChange?()
    }
}
