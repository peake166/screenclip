import AppKit
import Foundation

@main enum OpenSourceScrollStitcherTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ passed: Bool, _ name: String) {
            print("\(passed ? "PASS" : "FAIL") \(name)")
            if !passed { failures += 1 }
        }

        let width = 640, viewportHeight = 560, documentHeight = 4600
        func document(highlight: Bool = false, unrelated: Bool = false, topInset: Int = 24) throws -> CGImage {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
                pixelsHigh: documentHeight, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CaptureError.invalidImage }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: width, height: documentHeight).fill()
            for index in 0..<((documentHeight - 50) / 32) {
                let top = topInset + index * 32
                if highlight && index == 8 {
                    NSColor(white: 0.9, alpha: 1).setFill()
                    NSRect(x: 12, y: documentHeight - top - 28, width: width - 24, height: 32).fill()
                }
                let line = unrelated
                    ? String(format: "OTHER %03d Different section %d has separate content.", index, index * 911 + 41)
                    : String(format: "ROW %03d Daily notes: item %d, measured detail %d.", index, index * 137 + 17, index * 23 + 3)
                (line as NSString).draw(in: NSRect(x: 20, y: documentHeight - top - 26, width: width - 40, height: 26),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 18), .foregroundColor: NSColor.black])
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.cgImage else { throw CaptureError.invalidImage }
            return image
        }
        let fullDocument = try document()
        func viewport(_ offset: Int, source: CGImage? = nil, croppedWidth: Int? = nil) throws -> CGImage {
            guard let image = (source ?? fullDocument).cropping(to: CGRect(x: 0, y: offset,
                width: croppedWidth ?? width, height: viewportHeight)) else { throw CaptureError.invalidImage }
            return image
        }
        func isAppend(_ decision: StitchDecision) -> Bool {
            if case .appended(let rows) = decision { return rows > 0 }
            return false
        }
        // Pick a row from every independently rendered line, then verify those rows
        // appear in document order. This permits the vendor's static-margin trimming.
        func containsAllTextLines(_ output: Raster, reference: Raster) -> Bool {
            let stride = width * 4
            var signatures: [[UInt8]] = []
            var strongestRow: [UInt8]?, strongestCount = 0
            for y in 0..<reference.height {
                let row = Array(reference.bytes[(y * stride)..<((y + 1) * stride)])
                let dark = (0..<width).filter { row[$0 * 4] < 150 }.count
                if dark >= 20 {
                    if dark > strongestCount { strongestCount = dark; strongestRow = row }
                } else if let selectedRow = strongestRow {
                    signatures.append(selectedRow)
                    strongestCount = 0
                    strongestRow = nil
                }
            }
            // A line intersecting the bottom edge is incomplete in the source
            // itself. Check every complete line, including all internal joins.
            var nextRow = 0
            for (index, signature) in signatures.enumerated() {
                var found = false
                while nextRow < output.height {
                    let start = nextRow * stride
                    var error = 0
                    for x in 0..<width { error += abs(Int(output.bytes[start + x * 4]) - Int(signature[x * 4])) }
                    nextRow += 1
                    if error <= width { found = true; break }
                }
                if !found {
                    print("DETAIL text line signature \(index + 1)/\(signatures.count) missing; searched output height \(output.height)")
                    return false
                }
            }
            return signatures.count >= 20
        }

        let empty = OpenSourceScrollStitcher()
        do { _ = try await empty.image(); check(false, "an empty capture cannot produce an image") }
        catch { check(true, "an empty capture cannot produce an image") }

        let stitcher = OpenSourceScrollStitcher()
        let first = try await stitcher.accept(viewport(0))
        check(first.decision == .started && first.width == width && first.height == viewportHeight && first.frameCount == 1,
              "the first rendered text viewport starts the capture")
        let stationary = try await stitcher.accept(viewport(0))
        check(stationary.decision == .unchanged && stationary.height == first.height && stationary.frameCount == 1,
              "a duplicate text viewport does not grow the image")
        let hovered = try await stitcher.accept(viewport(0, source: document(highlight: true)))
        print("DETAIL rendered hover: \(hovered.decision); height=\(hovered.height); count=\(hovered.frameCount); \(hovered.debug ?? "")")
        let afterHover = try await stitcher.image()
        let firstRaster = try Raster(viewport(0))
        check(!isAppend(hovered.decision) && hovered.height == first.height && hovered.frameCount == 1
              && afterHover.bytes == firstRaster.bytes,
              "a stationary row highlight does not grow the image")
        var previousOffset = 0
        for offset in [173, 326, 469] {
            let update = try await stitcher.accept(viewport(offset), expectedSignedDeltaPixels: offset - previousOffset)
            check(isAppend(update.decision), "real rendered text at offset \(offset) appends through the vendor matcher")
            print("DETAIL rendered offset \(offset): \(update.decision); height=\(update.height); \(update.debug ?? "")")
            previousOffset = offset
        }
        let renderedResult = try await stitcher.image()
        let reference = try Raster(fullDocument.cropping(to: CGRect(x: 0, y: 0, width: width, height: viewportHeight + 469))!)
        check(containsAllTextLines(renderedResult, reference: reference),
              "the merged image retains every complete rendered text line in reading order")
        let lastViewport = try Raster(viewport(469))
        let boundaryBytes = width * 80 * 4
        check(renderedResult.bytes.prefix(boundaryBytes) == firstRaster.bytes.prefix(boundaryBytes),
              "the complete top boundary retains every glyph pixel from the first viewport")
        check(renderedResult.bytes.suffix(boundaryBytes) == lastViewport.bytes.suffix(boundaryBytes),
              "the complete bottom boundary retains every glyph pixel from the last viewport")
        check(renderedResult.width == reference.width && renderedResult.height == reference.height
              && renderedResult.bytes == reference.bytes,
              "the complete rendered document has no missing or duplicated pixel rows, including both boundaries")

        let edgeDocument = try document(topInset: 10)
        let edgeStitcher = OpenSourceScrollStitcher()
        let edgeFirst = try Raster(viewport(0, source: edgeDocument))
        _ = try await edgeStitcher.accept(viewport(0, source: edgeDocument))
        for offset in [160, 320, 480] {
            let update = try await edgeStitcher.accept(viewport(offset, source: edgeDocument), expectedSignedDeltaPixels: 160)
            check(isAppend(update.decision), "text close to the top boundary appends at offset \(offset)")
        }
        let edgeOutput = try await edgeStitcher.image()
        let edgeLast = try Raster(viewport(480, source: edgeDocument))
        let edgeReference = try Raster(edgeDocument.cropping(to: CGRect(x: 0, y: 0,
            width: width, height: viewportHeight + 480))!)
        check(edgeOutput.bytes.prefix(boundaryBytes) == edgeFirst.bytes.prefix(boundaryBytes),
              "the first close-to-edge text is retained completely rather than only its strongest scanline")
        check(edgeOutput.bytes.suffix(boundaryBytes) == edgeLast.bytes.suffix(boundaryBytes),
              "the final close-to-edge text is retained completely rather than only its strongest scanline")
        check(edgeOutput.height == edgeReference.height && edgeOutput.bytes == edgeReference.bytes,
              "close-to-edge text is complete with no duplicate or missing pixel rows")

        let unguided = OpenSourceScrollStitcher()
        _ = try await unguided.accept(viewport(0))
        for offset in [173, 326, 469] {
            let update = try await unguided.accept(viewport(offset))
            check(isAppend(update.decision), "rendered text at offset \(offset) appends without a scroll-distance hint")
        }
        let unguidedImage = try await unguided.image()
        check(containsAllTextLines(unguidedImage, reference: reference),
              "unguided matching preserves every complete rendered text line in reading order")

        let preserved = renderedResult.bytes
        let backtrack = try await stitcher.accept(viewport(326), expectedSignedDeltaPixels: -143)
        let afterBacktrack = try await stitcher.image()
        check(!isAppend(backtrack.decision) && afterBacktrack.bytes == preserved,
              "backtracking does not duplicate previously captured text")
        let resized = try await stitcher.accept(viewport(469, croppedWidth: width - 20))
        let afterResize = try await stitcher.image()
        check(resized.decision == .sizeChanged && afterResize.bytes == preserved,
              "a changed selection size leaves the accepted image intact")
        let unrelated = try await stitcher.accept(viewport(1200, source: document(unrelated: true)))
        let afterUnrelated = try await stitcher.image()
        check(unrelated.decision == .noOverlap && afterUnrelated.bytes == preserved,
              "an unrelated viewport is rejected without damaging the accepted image")

        let tooSmall = OpenSourceScrollStitcher(pixelLimit: width * (viewportHeight - 1))
        let rejected = try await tooSmall.accept(viewport(0))
        check(rejected.decision == .limitReached && rejected.frameCount == 0,
              "a first viewport above the pixel limit is rejected before accepting pixels")
        let capped = OpenSourceScrollStitcher(pixelLimit: width * 650)
        _ = try await capped.accept(viewport(0))
        let cappedUpdate = try await capped.accept(viewport(173), expectedSignedDeltaPixels: 173)
        let cappedImage = try await capped.image()
        check(cappedUpdate.decision == .limitReached && cappedImage.width * cappedImage.height <= width * 650,
              "an append respects the full-resolution pixel limit")
        check(cappedImage.height == cappedUpdate.height,
              "the reported capped output height includes its preserved boundary pixels")
        check(cappedImage.bytes == firstRaster.bytes && cappedUpdate.frameCount == 1,
              "an oversized next segment leaves the entire previously accepted image intact instead of skipping content")

        let fineScrolling = OpenSourceScrollStitcher()
        _ = try await fineScrolling.accept(viewport(0))
        var fineAccepted = 1, fineHitLimit = false
        for offset in stride(from: 14, through: 2800, by: 14) {
            let update = try await fineScrolling.accept(viewport(offset))
            fineAccepted = update.frameCount
            if update.decision == .limitReached { fineHitLimit = true; break }
        }
        let fineOutput = try await fineScrolling.image()
        let fineReference = try Raster(fullDocument.cropping(to: CGRect(x: 0, y: 0,
            width: width, height: viewportHeight + 2800))!)
        print("DETAIL fine scrolling: accepted=\(fineAccepted); hitLimit=\(fineHitLimit); height=\(fineOutput.height)")
        check(!fineHitLimit && fineAccepted >= 180,
              "two hundred fine scroll updates can accept over 180 slices without a per-frame memory limit")
        check(fineOutput.height == fineReference.height && fineOutput.bytes == fineReference.bytes,
              "fine scrolling across six viewports retains every pixel row without gaps or duplicate boundaries")

        if CommandLine.arguments.count > 1 {
            let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            func savedImage(_ index: Int) throws -> CGImage {
                let data = try Data(contentsOf: folder.appendingPathComponent(String(format: "%03d.png", index)))
                guard let image = NSBitmapImageRep(data: data)?.cgImage else { throw CaptureError.invalidImage }
                return image
            }
            let hoverReplay = OpenSourceScrollStitcher()
            let start = try await hoverReplay.accept(savedImage(1))
            let hover = try await hoverReplay.accept(savedImage(2))
            check(hover.decision == .unchanged && hover.height == start.height,
                  "authorized saved Netease hover frames do not grow the image")
            let replay = OpenSourceScrollStitcher()
            let initial = try await replay.accept(savedImage(11))
            var count = initial.frameCount
            for index in [12, 13, 14, 15] {
                let update = try await replay.accept(savedImage(index))
                check(isAppend(update.decision) && update.frameCount == count + 1,
                      "authorized saved Netease frame \(index) really appends through the vendor matcher")
                print("DETAIL saved frame \(index): \(update.decision); height=\(update.height); \(update.debug ?? "")")
                count = update.frameCount
            }
            let finished = try await replay.image()
            check(finished.width == initial.width && finished.height > initial.height,
                  "the accepted saved Netease sequence produces a longer image")
        }
        if failures > 0 { print("\(failures) open-source scrolling checks failed"); exit(1) }
        print("All open-source scrolling checks passed; no screen capture, image output, upload or provider call")
    }
}
