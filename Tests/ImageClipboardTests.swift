import AppKit
import CoreGraphics
import Foundation

@main enum ImageClipboardTests {
    @MainActor static func main() throws {
        var failures = 0
        func check(_ passed: Bool, _ message: String) {
            print("\(passed ? "PASS" : "FAIL") \(message)")
            if !passed { failures += 1 }
        }

        // Independent known colors for every row make channel swaps, flips and
        // omitted rows observable without relying on a stitching implementation.
        func coloredRaster(offset: Int, height: Int) -> Raster {
            let width = 72
            let bytes = (offset..<(offset + height)).flatMap { y in
                (0..<width).flatMap { x -> [UInt8] in
                    [UInt8((y * 3 + x * 11) % 256), UInt8((y * 7 + x) % 256),
                     UInt8((y * 13 + x * 5) % 256), 255]
                }
            }
            return Raster(width: width, height: height, bytes: bytes)
        }

        let first = coloredRaster(offset: 0, height: 180)
        let roundTrip = try Raster(first.cgImage())
        check(roundTrip.width == first.width && roundTrip.height == first.height &&
              roundTrip.bytes == first.bytes,
              "CGImage conversion preserves actual colored pixels, dimensions and row orientation")

        let second = coloredRaster(offset: 93, height: 180)
        let expected = coloredRaster(offset: 0, height: 273)
        let joined = try Raster.join([first, second.bottom(93)])
        check(joined.width == expected.width && joined.height == expected.height &&
              joined.bytes == expected.bytes,
              "joining known image strips retains every expected colored row exactly once")

        let longImage = coloredRaster(offset: 0, height: 1700)
        let encoded = try longImage.png()
        guard let pngImage = NSBitmapImageRep(data: encoded)?.cgImage else {
            throw CaptureError.invalidImage
        }
        let decoded = try Raster(pngImage)
        check(decoded.width == longImage.width && decoded.height == 1700 &&
              decoded.bytes == longImage.bytes,
              "PNG round trip preserves the entire long image and every colored pixel")

        // A real, separately named macOS pasteboard keeps the user's clipboard
        // untouched while exercising the production copy and readback path.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try ImageClipboard.copy(longImage, to: board)
        guard let pastedData = board.data(forType: .png),
              let pastedImage = NSBitmapImageRep(data: pastedData)?.cgImage else {
            throw CaptureError.invalidImage
        }
        let pasted = try Raster(pastedImage)
        check(pasted.width == longImage.width && pasted.height == 1700 &&
              pasted.bytes == longImage.bytes,
              "copying and reading a real isolated pasteboard preserves the complete long image")

        let originalChangeCount = board.changeCount
        do {
            try ImageClipboard.copy(Raster(width: 1, height: 1, bytes: []), to: board)
            check(false, "an invalid image is rejected before changing the pasteboard")
        } catch {
            check(error as? CaptureError == .invalidImage,
                  "an invalid image reports an image error")
            check(board.changeCount == originalChangeCount && board.data(forType: .png) == pastedData,
                  "a failed copy neither clears nor changes the previously copied long image")
        }

        if failures > 0 { print("\(failures) image and clipboard checks failed"); exit(1) }
        print("All image and isolated clipboard checks passed")
    }
}
