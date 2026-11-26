import AppKit
import Carbon
import ImageIO
import UniformTypeIdentifiers

private final class WeakCGImageRef {
    weak var image: CGImage?
    init(_ image: CGImage?) { self.image = image }
}

@main struct PinnedImageTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var failures = 0
        func check(_ value: Bool, _ label: String) {
            print("\(value ? "PASS" : "FAIL") \(label)")
            if !value { failures += 1 }
        }
        func makeRaster(width: Int, height: Int, r: UInt8 = 64, g: UInt8 = 128, b: UInt8 = 240) -> Raster {
            var bytes = [UInt8](repeating: 255, count: width * height * 4)
            for i in stride(from: 0, to: bytes.count, by: 4) {
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
            return Raster(width: width, height: height, bytes: bytes)
        }
        func allSubviews(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(allSubviews)
        }

        guard let screen = NSScreen.main else { fatalError("A logged-in desktop is required") }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        // 1. Layout geometry: 1:1 Retina scaling, in-place placement, negative-coordinate displays, oversize protection.
        let natural = PinnedImageLayout.naturalSize(pixelWidth: 800, pixelHeight: 600, backingScale: 2)
        check(natural == CGSize(width: 400, height: 300), "Retina 2x pixels convert to 1:1 logical dimensions")

        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let anchor = CGRect(x: 200, y: 300, width: 400, height: 300)
        let inPlace = PinnedImageLayout.initialFrame(naturalSize: natural, anchorRect: anchor, visibleFrame: visible)
        check(inPlace.frame == anchor && abs(inPlace.scale - 1.0) < 0.001,
              "in-place screenshot pins at exact 1:1 size and original selection rect")

        let tallScroll = PinnedImageLayout.initialFrame(
            naturalSize: CGSize(width: 400, height: 2400),
            anchorRect: CGRect(x: 200, y: 300, width: 400, height: 300),
            visibleFrame: visible
        )
        check(visible.contains(tallScroll.frame) && tallScroll.scale < 1.0 && tallScroll.frame.height <= visible.height - 24,
              "tall scrolling screenshot shrinks proportionally to fit within screen bounds")

        let negativeDisplay = CGRect(x: -1440, y: -200, width: 1440, height: 875)
        let hugePhoto = PinnedImageLayout.initialFrame(
            naturalSize: CGSize(width: 4000, height: 3000),
            anchorRect: nil,
            visibleFrame: negativeDisplay,
            cascadeIndex: 0
        )
        check(negativeDisplay.contains(hugePhoto.frame) && hugePhoto.frame.width <= negativeDisplay.width * 0.80 + 1,
              "large external images fit cleanly within 80% of negative-coordinate display bounds")

        let cascade0 = PinnedImageLayout.initialFrame(naturalSize: CGSize(width: 300, height: 200), anchorRect: nil, visibleFrame: visible, cascadeIndex: 0)
        let cascade1 = PinnedImageLayout.initialFrame(naturalSize: CGSize(width: 300, height: 200), anchorRect: nil, visibleFrame: visible, cascadeIndex: 1)
        check(cascade1.frame.minX == cascade0.frame.minX + PinnedImageLayout.cascadeStep
              && cascade1.frame.minY == cascade0.frame.minY - PinnedImageLayout.cascadeStep,
              "multiple non-anchored pinned images cascade instead of stacking identically")

        let zoomed = PinnedImageLayout.scaledFrame(
            currentFrame: anchor,
            naturalSize: natural,
            targetScale: 100.0,
            anchorInWindow: CGPoint(x: 200, y: 150),
            visibleFrame: visible
        )
        check(zoomed.scale == PinnedImageLayout.maximumScale, "zoom scale clamps cleanly at maximum bound")

        let shrunk = PinnedImageLayout.scaledFrame(
            currentFrame: anchor,
            naturalSize: natural,
            targetScale: 0.01,
            anchorInWindow: CGPoint(x: 200, y: 150),
            visibleFrame: visible
        )
        check(shrunk.scale >= PinnedImageLayout.minimumScale && max(shrunk.frame.width, shrunk.frame.height) >= PinnedImageLayout.minimumEdge - 1,
              "zoom scale clamps cleanly at minimum bound so pinned images never vanish")

        check(PinnedImageLayout.clampedOpacity(0.05) == PinnedImageLayout.minimumOpacity
              && PinnedImageLayout.clampedOpacity(2.0) == PinnedImageLayout.maximumOpacity,
              "opacity clamps between 20% and 100%")

        // 2. Loader: PNG/TIFF pasteboard, file URL on pasteboard, EXIF orientation, invalid/empty errors.
        board.clearContents()
        do {
            _ = try PinnedImageLoader.loadFromPasteboard(board)
            check(false, "empty pasteboard reports a clear missing-image error")
        } catch PinnedImageError.noClipboardImage {
            check(true, "empty pasteboard reports a clear missing-image error")
        }

        let sample = makeRaster(width: 120, height: 80, r: 30, g: 144, b: 255)
        try ImageClipboard.copy(sample, to: board)
        let fromBoard = try PinnedImageLoader.loadFromPasteboard(board)
        check(fromBoard.width == 120 && fromBoard.height == 80, "loader reads PNG image directly from pasteboard")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-pin-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pngURL = tempDir.appendingPathComponent("sample.png")
        try sample.png().write(to: pngURL)
        board.clearContents()
        let urlItem = NSPasteboardItem()
        urlItem.setString(pngURL.absoluteString, forType: .fileURL)
        board.writeObjects([urlItem])
        let fromFileURLBoard = try PinnedImageLoader.loadFromPasteboard(board)
        check(fromFileURLBoard.width == 120 && fromFileURLBoard.height == 80,
              "loader supports Finder-copied image file URLs on the pasteboard")

        // EXIF rotated image (orientation 6 = 90° CW): 120x80 encoded becomes 80x120 displayed.
        let rotatedURL = tempDir.appendingPathComponent("rotated.jpg")
        if let dest = CGImageDestinationCreateWithURL(rotatedURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, try sample.cgImage(), [kCGImagePropertyOrientation: 6] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        let rotated = try PinnedImageLoader.load(url: rotatedURL)
        check(rotated.width == 80 && rotated.height == 120,
              "loader applies EXIF orientation transforms when opening local photos")

        let brokenURL = tempDir.appendingPathComponent("broken.png")
        try Data("not-an-image".utf8).write(to: brokenURL)
        do {
            _ = try PinnedImageLoader.load(url: brokenURL)
            check(false, "invalid image files fail cleanly with an error")
        } catch PinnedImageError.unreadableFile {
            check(true, "invalid image files fail cleanly with an error")
        }

        // 3. PinnedImageManager & PinnedImagePanel lifecycle, zoom/opacity/spaces/OCR/copy/hide/close/memory.
        var changeEvents = 0
        var translatedSizes: [(Int, Int)] = []
        let manager = PinnedImageManager(pasteboard: board, recognize: { _ in "Pinned OCR text\n第二行" })
        manager.onChange = { changeEvents += 1 }
        manager.onTranslate = { translatedSizes.append(($0.width, $0.height)) }

        let region = CaptureRegion(screen: screen, rect: CGRect(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.minY + 120, width: 240, height: 160))
        let staticShot = makeRaster(
            width: Int((240 * screen.backingScaleFactor).rounded()),
            height: Int((160 * screen.backingScaleFactor).rounded()),
            r: 22, g: 120, b: 220
        )
        let p1 = try manager.pin(staticShot, region: region, present: false)
        check(manager.count == 1 && p1.level == .floating && p1.styleMask.contains(.nonactivatingPanel)
              && p1.collectionBehavior.contains(.canJoinAllSpaces) && p1.collectionBehavior.contains(.fullScreenAuxiliary),
              "pinned panel uses floating non-activating cross-space configuration")
        check(abs(p1.frame.width - 240) <= 1 && abs(p1.frame.height - 160) <= 1,
              "static screenshot pins at 1:1 logical dimensions")

        // Verify scrolling screenshot keeps true aspect ratio instead of squishing into capture box.
        let scrollShot = makeRaster(
            width: Int((200 * screen.backingScaleFactor).rounded()),
            height: Int((1400 * screen.backingScaleFactor).rounded()),
            r: 40, g: 160, b: 120
        )
        let pScroll = try manager.pin(scrollShot, region: region, present: false)
        let expectedRatio = CGFloat(scrollShot.width) / CGFloat(scrollShot.height)
        let actualRatio = pScroll.frame.width / pScroll.frame.height
        check(abs(actualRatio - expectedRatio) < 0.03 && screen.visibleFrame.contains(pScroll.frame),
              "scrolling screenshot preserves true tall aspect ratio inside screen bounds")

        // Zoom, opacity, spaces toggle, copy image, OCR, translate.
        p1.zoomIn()
        check(p1.scaleFactor > 1.1 && p1.frame.width > 240, "zoomIn scales pinned panel upward")
        p1.resetScale()
        check(abs(p1.scaleFactor - 1.0) < 0.01 && abs(p1.frame.width - 240) <= 1, "resetScale restores 100% size")
        p1.setOpacity(0.5)
        check(abs(p1.imageOpacity - 0.5) < 0.001 && abs(p1.alphaValue - 0.5) < 0.001, "opacity updates panel alpha accurately")
        p1.toggleSticksToAllSpaces()
        check(!p1.sticksToAllSpaces && !p1.collectionBehavior.contains(.canJoinAllSpaces),
              "panel can switch between all spaces and current space")
        p1.toggleSticksToAllSpaces()
        check(p1.sticksToAllSpaces && p1.collectionBehavior.contains(.canJoinAllSpaces),
              "panel switches back to sticking across all spaces")

        board.clearContents()
        p1.copyImageToPasteboard()
        check(board.data(forType: .png) != nil, "pinned panel copies PNG back to pasteboard")

        p1.copyRecognizedText()
        for _ in 0..<200 {
            if board.string(forType: .string) == "Pinned OCR text\n第二行" { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        check(board.string(forType: .string) == "Pinned OCR text\n第二行",
              "pinned panel runs local OCR and writes recognized text to pasteboard")

        p1.translatePinnedImage()
        check(translatedSizes.count == 1 && translatedSizes[0].0 == staticShot.width,
              "pinned panel dispatches translate action with its image")

        let menu = p1.buildContextMenu()
        let titles = menu.items.map(\.title)
        check(titles.contains("复制图片") && titles.contains("复制图中文字") && titles.contains("翻译此图")
              && titles.contains("另存为 PNG…") && titles.contains("透明度")
              && titles.contains(where: { $0.hasPrefix("关闭全部贴图") }),
              "context menu exposes all pinned actions including close-all when multiple pins exist")

        // Hide/show all and close lifecycle.
        manager.toggleHideAll(present: false)
        check(manager.areHidden && manager.count == 2, "hide-all hides panels without destroying them")
        let p3 = try manager.pin(sample, screen: screen, present: false)
        check(!manager.areHidden && manager.count == 3, "pinning a new image automatically restores hidden state")

        // Memory reclamation check on close.
        var weakRef: WeakCGImageRef?
        autoreleasepool {
            let ephemeral = makeRaster(width: 96, height: 64, r: 200, g: 80, b: 80)
            let panel = try! manager.pin(ephemeral, screen: screen, present: false)
            weakRef = WeakCGImageRef(panel.displayedImage)
            check(weakRef?.image != nil, "active pinned panel retains its displayed CGImage")
            panel.requestClose()
        }
        check(weakRef?.image == nil && manager.count == 3, "closing a pinned panel immediately releases its CGImage and removes it from manager")

        manager.close(pScroll)
        check(manager.count == 2 && pScroll.isClosed && pScroll.raster == nil, "closing one panel leaves sibling panels intact")
        manager.closeAll()
        check(manager.count == 0 && p1.isClosed && p3.isClosed && changeEvents > 0, "closeAll releases every pinned panel cleanly")

        // 4. CaptureResultController: pin button triggers callback and still works after OCR completes.
        let captureController = CaptureResultController(pasteboard: board, recognize: { _ in "OCR first" })
        defer { captureController.close() }
        var pinnedFromStrip: (Raster, CaptureRegion)?
        captureController.onPin = { img, reg in pinnedFromStrip = (img, reg) }
        captureController.show(sample, region: region, message: "已复制图片", present: false)
        check(captureController.panel!.frame.width <= 368 && captureController.panel!.frame.height == 52,
              "capture action strip stays within compact width and height after adding pin button")
        NSApp.sendAction(captureController.copyButton.action!, to: captureController.copyButton.target, from: captureController.copyButton)
        for _ in 0..<200 where captureController.phase == .recognizing { try await Task.sleep(nanoseconds: 5_000_000) }
        check(captureController.phase == .copied, "copy-text still succeeds on the updated action strip")
        NSApp.sendAction(captureController.pinButton.action!, to: captureController.pinButton.target, from: captureController.pinButton)
        check(captureController.phase == .closed && pinnedFromStrip?.0.width == 120 && pinnedFromStrip?.1.rect == region.rect,
              "clicking pin on the action strip still pins the screenshot even after copy-text ran")

        // 5. ClipboardHistoryWindow: image entry shows '贴到屏幕' and passes full-resolution image data; text entry hides it.
        let historyFolder = tempDir.appendingPathComponent("history")
        let suite = "com.local.screenclip.pin-clipboard." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ClipboardHistory(
            board: board,
            defaults: defaults,
            directory: historyFolder,
            encryptionKey: Data(repeating: 0x33, count: 32),
            source: { ("Test App", "test.app") }
        )
        await history.flush(); history.setRecording(true); await history.flush()
        board.clearContents(); board.setString("Plain text item", forType: .string); history.poll(); await history.flush()
        let hiRes = makeRaster(width: 1600, height: 900, r: 90, g: 180, b: 110)
        try ImageClipboard.copy(hiRes, to: board); history.poll(); await history.flush()

        let picker = ClipboardHistoryWindow(history: history)
        defer { history.onChange = nil; picker.close() }
        var pinnedHistoryData: Data?
        picker.onPinImageData = { pinnedHistoryData = $0 }
        picker.refresh()
        let pinHistoryButton = allSubviews(picker.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "贴到屏幕" }
        check(pinHistoryButton != nil && pinHistoryButton?.isHidden == false,
              "clipboard picker reveals the pin-to-screen button when an image entry is selected")
        pinHistoryButton?.performClick(nil)
        for _ in 0..<200 where pinnedHistoryData == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        if let pinnedHistoryData {
            let decoded = try PinnedImageLoader.load(data: pinnedHistoryData)
            check(decoded.width == 1600 && decoded.height == 900,
                  "pinning from clipboard history decodes the original full-resolution image instead of a 1200px thumbnail")
        } else {
            check(false, "pinning from clipboard history delivers image data")
        }

        // Select text entry and confirm pin-to-screen hides.
        let table = allSubviews(picker.contentView!).compactMap { $0 as? NSTableView }.first!
        for row in 0..<table.numberOfRows {
            if picker.tableView(table, shouldSelectRow: row), row != table.selectedRow {
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                picker.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
                break
            }
        }
        check(pinHistoryButton?.isHidden == true, "clipboard picker hides the pin-to-screen button for text entries")

        // 6. Shortcut v3 -> v4 migration & unique hotKeyIDs.
        struct V3Saved: Codable { let copy: Shortcut?; let scroll: Shortcut?; let translate: Shortcut?; let clipboard: Shortcut?; let version: Int }
        let customCopy = Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "A")
        defaults.set(try JSONEncoder().encode(V3Saved(copy: customCopy, scroll: nil, translate: Shortcut.defaults[.translate], clipboard: Shortcut.defaults[.clipboard], version: 3)),
                     forKey: "captureShortcuts.v1")
        let migrated = ShortcutPreferences(defaults: defaults) { _ in true }
        check(migrated.bindings[.copy] == customCopy && migrated.bindings[.scroll] == nil
              && migrated.bindings[.pinCapture] == Shortcut.defaults[.pinCapture]
              && migrated.bindings[.pinClipboard] == Shortcut.defaults[.pinClipboard],
              "v3 -> v4 shortcut migration preserves existing choices and adds pin defaults when free")

        defaults.set(try JSONEncoder().encode(V3Saved(copy: Shortcut.defaults[.pinCapture], scroll: Shortcut.defaults[.pinClipboard], translate: nil, clipboard: nil, version: 3)),
                     forKey: "captureShortcuts.v1")
        let conflict = ShortcutPreferences(defaults: defaults) { _ in true }
        check(conflict.bindings[.copy] == Shortcut.defaults[.pinCapture]
              && conflict.bindings[.scroll] == Shortcut.defaults[.pinClipboard]
              && conflict.bindings[.pinCapture] == nil
              && conflict.bindings[.pinClipboard] == nil,
              "v3 -> v4 migration never steals shortcuts already assigned by the user")

        let allIDs = ShortcutAction.allCases.map(\.hotKeyID)
            + [CaptureHotKeyID.scrollCancel, CaptureHotKeyID.translationCancel, CaptureHotKeyID.selectionCancel, CaptureHotKeyID.resultCancel]
        check(Set(allIDs).count == allIDs.count, "all permanent and temporary hotKey IDs remain globally unique")

        // 7. Render light and dark previews of a pinned image panel (normal & hovered).
        let previewDir = URL(fileURLWithPath: ".build/previews")
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        let previewPanel = try manager.pin(staticShot, region: region, present: false)
        for (suffix, hovered, hud) in [("light", false, nil as String?), ("dark", false, nil), ("hover", true, "120%")] {
            let dark = suffix != "light"
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            previewPanel.appearance = appearance
            previewPanel.contentView?.appearance = appearance
            previewPanel.setHoverStateForPreview(hovered, hud: hud)
            previewPanel.contentView?.layoutSubtreeIfNeeded()
            if let view = previewPanel.contentView,
               let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                try bitmap.representation(using: .png, properties: [:])!
                    .write(to: previewDir.appendingPathComponent("pinned-\(suffix).png"))
            }
        }
        manager.closeAll()

        if failures > 0 {
            print("\(failures) pinned image checks failed")
            exit(1)
        }
        print("All pinned image checks passed")
    }
}
