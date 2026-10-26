import AppKit
import ScreenCaptureKit

struct FrozenScreenFrame {
    let displayID: CGDirectDisplayID
    let screenFrame: CGRect
    let image: CGImage

    func crop(_ rect: CGRect) throws -> Raster {
        let selected = rect.intersection(screenFrame)
        guard !selected.isNull, selected.width > 0, selected.height > 0,
              screenFrame.width > 0, screenFrame.height > 0 else { throw CaptureError.invalidSelection }
        let scaleX = CGFloat(image.width) / screenFrame.width, scaleY = CGFloat(image.height) / screenFrame.height
        // AppKit uses a bottom-left origin; captured image pixels start at the top left.
        let pixels = CGRect(x: (selected.minX - screenFrame.minX) * scaleX,
                            y: (screenFrame.maxY - selected.maxY) * scaleY,
                            width: selected.width * scaleX, height: selected.height * scaleY)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return try autoreleasepool {
            guard let cropped = image.cropping(to: pixels) else { throw CaptureError.invalidSelection }
            return try Raster(cropped)
        }
    }
}

@MainActor enum FrozenScreenCapture {
    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    static func capture(_ screens: [NSScreen]) async throws -> [FrozenScreenFrame] {
        guard !screens.isEmpty else { return [] }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        var frames: [FrozenScreenFrame] = []
        for screen in screens {
            try Task.checkCancellation()
            guard let id = displayID(screen), let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.missingDisplay
            }
            let filter: SCContentFilter
            if ownApps.isEmpty {
                filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { $0.owningApplication?.processID == ownPID })
            } else { filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: []) }
            let frame = screen.frame, config = SCStreamConfiguration()
            config.sourceRect = CGRect(origin: .zero, size: frame.size)
            config.width = max(1, Int((frame.width * screen.backingScaleFactor).rounded()))
            config.height = max(1, Int((frame.height * screen.backingScaleFactor).rounded()))
            config.showsCursor = false; config.capturesAudio = false; config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            frames.append(FrozenScreenFrame(displayID: id, screenFrame: frame, image: image))
        }
        return frames
    }
}
