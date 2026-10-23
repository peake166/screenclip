import CoreGraphics
import Foundation

// The matching implementation comes from andynvt/snapzy, commit
// dec0e794503c3595ee2fe3462aafe5effa70f966. Local changes preserve the outer
// screenshot margins, retain only useful slice rows, and budget full output. See
// Resources/ThirdPartyLicenses/Snapzy-SOURCE.txt and Snapzy-LICENSE.txt.
actor OpenSourceScrollStitcher {
    struct Update {
        let decision: StitchDecision
        let width: Int
        let height: Int
        let frameCount: Int
        let debug: String?
    }

    private let pixelLimit: Int
    // Local ContentSlice storage owns only useful rows. The pixel limit bounds
    // those rows plus the full first/last matching viewports, independently of
    // how many small scrolling movements were accepted.
    private let stitcher = ScrollingCaptureStitcher()
    private var width = 0
    private var viewportHeight = 0
    private var frameCount = 0

    init(pixelLimit: Int = 32_000_000) { self.pixelLimit = pixelLimit }

    func accept(_ image: CGImage, expectedSignedDeltaPixels: Int? = nil) throws -> Update {
        if frameCount > 0, image.width != width || image.height != viewportHeight {
            return currentUpdate(.sizeChanged)
        }
        guard image.width > 0, image.height > 0,
              image.width <= max(0, pixelLimit) / image.height else {
            return currentUpdate(.limitReached, incomingWidth: image.width)
        }
        let vendorUpdate: ScrollingCaptureStitchUpdate?
        if frameCount == 0 {
            vendorUpdate = stitcher.start(with: image)
        } else {
            // The upstream matcher takes abs(hint); Int.min has no positive Int
            // representation and cannot be a meaningful screen displacement.
            let hint = expectedSignedDeltaPixels == Int.min ? nil : expectedSignedDeltaPixels
            vendorUpdate = stitcher.append(image, maxOutputHeight: pixelLimit / width,
                expectedSignedDeltaPixels: hint, renderMergedImage: false)
        }
        guard let vendorUpdate else { throw CaptureError.invalidImage }
        width = image.width
        viewportHeight = image.height
        frameCount = vendorUpdate.acceptedFrameCount
        let decision: StitchDecision
        switch vendorUpdate.outcome {
        case .initialized: decision = .started
        case .appended(let rows): decision = .appended(rows)
        case .ignoredNoMovement: decision = .unchanged
        case .ignoredAlignmentFailed: decision = .noOverlap
        case .reachedHeightLimit: decision = .limitReached
        }
        let debug = vendorUpdate.alignmentDebug.map {
            "path=\($0.path.rawValue); confidence=\($0.confidence); vision=\($0.usedVisionEstimate); agreement=\($0.visionAgreementCount); delta=\($0.appendDeltaY ?? 0)"
        }
        return Update(decision: decision, width: width, height: vendorUpdate.outputHeight + stitcher.marginHeight,
            frameCount: frameCount, debug: debug)
    }

    func image() throws -> Raster {
        guard let image = stitcher.mergedImagePreservingMargins() else { throw CaptureError.noImage }
        return try Raster(image)
    }

    private func currentUpdate(_ decision: StitchDecision, incomingWidth: Int = 0) -> Update {
        Update(decision: decision, width: width > 0 ? width : incomingWidth,
            height: stitcher.outputHeight + stitcher.marginHeight, frameCount: frameCount, debug: nil)
    }
}
