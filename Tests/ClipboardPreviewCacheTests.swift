import AppKit

private final class WeakPreviewImage {
    weak var image: CGImage?
    init(_ image: CGImage) { self.image = image }
}

@MainActor private final class PreviewProbe {
    struct Request { let id: UUID; let pixels: Int }
    var imageIDs: Set<UUID> = []
    var requests: [Request] = []
    var largeImages: [WeakPreviewImage] = []
    var delayLargeImages = false
    private var pending: [(UUID, (ClipboardHistoryPreview?) -> Void)] = []
    var pendingCount: Int { pending.count }
    var largeRequests: Int { requests.filter { $0.pixels > 80 && imageIDs.contains($0.id) }.count }
    var thumbnailRequests: Int { requests.filter { $0.pixels == 80 }.count }
    var textRequests: Int { requests.filter { !imageIDs.contains($0.id) }.count }
    var liveLargeImages: Int { largeImages.filter { $0.image != nil }.count }
    func load(_ id: UUID, _ pixels: Int, _ completion: @escaping (ClipboardHistoryPreview?) -> Void) {
        requests.append(Request(id: id, pixels: pixels))
        if imageIDs.contains(id), pixels > 80, delayLargeImages { pending.append((id, completion)); return }
        deliver(id, pixels, completion)
    }
    private func deliver(_ id: UUID, _ pixels: Int, _ completion: (ClipboardHistoryPreview?) -> Void) {
        autoreleasepool {
            guard imageIDs.contains(id) else { completion(.init(text: "Cached text fixture", image: nil)); return }
            let width = pixels > 80 ? 1200 : 80, height = pixels > 80 ? 900 : 60
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.9, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            if pixels > 80 { largeImages.append(WeakPreviewImage(image)) }
            completion(.init(text: "", image: image))
        }
    }
    func finishPending(failing: Bool = false) {
        let callbacks = pending; pending.removeAll()
        for (id, completion) in callbacks { if failing { completion(nil) } else { deliver(id, 1200, completion) } }
    }
}

@MainActor private final class PreviewFixture {
    let board = NSPasteboard.withUniqueName()
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("screenclip-preview-cache-" + UUID().uuidString)
    let suite = "com.local.screenclip.preview-cache." + UUID().uuidString
    var defaults: UserDefaults { UserDefaults(suiteName: suite)! }
    var history: ClipboardHistory!
    var textID: UUID!, firstImageID: UUID!, latestImageID: UUID!
    var latestPNG = Data()
    let probe = PreviewProbe()
    func prepare() async throws {
        defaults.set(Data("fixture-shortcuts".utf8), forKey: "captureShortcuts.v1")
        defaults.set(Data("fixture-translation-settings".utf8), forKey: "translationSettings.v1")
        history = ClipboardHistory(board: board, defaults: defaults, directory: folder,
            encryptionKey: Data(repeating: 0x42, count: 32), source: { ("Fixture Editor", "fixture.editor") })
        await history.flush(); history.setRecording(true); await history.flush()
        board.clearContents(); board.setString("Cached text fixture", forType: .string); history.poll(); await history.flush()
        textID = history.entries[0].id
        for index in 0..<2 {
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 256,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: index == 0 ? 0.2 : 0.6, green: 0.4, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            board.clearContents(); board.setData(data, forType: .png); history.poll(); await history.flush()
            if index == 0 { firstImageID = history.entries[0].id }
            else { latestImageID = history.entries[0].id; latestPNG = data }
        }
        history.setPinned(latestImageID, true); await history.flush()
        probe.imageIDs = [firstImageID, latestImageID]
    }
    func window(delay: TimeInterval = 0.12) -> ClipboardHistoryWindow {
        ClipboardHistoryWindow(history: history, previewIdleDelay: delay, previewLoader: probe.load)
    }
    func cleanup() {
        history.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }
}

@main struct ClipboardPreviewCacheTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ value: Bool, _ label: String) { print("\(value ? "PASS" : "FAIL") \(label)"); if !value { failures += 1 } }
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        func table(_ window: ClipboardHistoryWindow) -> NSTableView { all(window.contentView!).compactMap { $0 as? NSTableView }.first! }
        func image(_ window: ClipboardHistoryWindow) -> NSImageView {
            all(window.contentView!).compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "剪贴板图片预览" }!
        }
        func select(_ id: UUID, in window: ClipboardHistoryWindow, history: ClipboardHistory) {
            let list = table(window)
            let rows = (0..<list.numberOfRows).filter { window.tableView(list, shouldSelectRow: $0) }
            let position = history.entries.firstIndex { $0.id == id }!
            list.selectRowIndexes(IndexSet(integer: rows[position]), byExtendingSelection: false)
            window.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        }
        func primeThumbnails(_ window: ClipboardHistoryWindow) {
            let list = table(window)
            for row in 0..<list.numberOfRows { _ = window.tableView(list, viewFor: list.tableColumns[0], row: row) }
        }
        func open(_ window: ClipboardHistoryWindow) -> Double {
            let started = ProcessInfo.processInfo.systemUptime
            autoreleasepool { window.present(targetName: "Fixture Editor"); window.contentView!.layoutSubtreeIfNeeded() }
            return (ProcessInfo.processInfo.systemUptime - started) * 1000
        }
        func idle() async throws { try await Task.sleep(nanoseconds: 220_000_000) }

        if CommandLine.arguments.contains("--default-idle") || CommandLine.arguments.contains("--real-idle") {
            let shortProof = CommandLine.arguments.contains("--real-idle")
            let fixture = PreviewFixture(); try await fixture.prepare(); defer { fixture.cleanup() }
            let context = CGContext(data: nil, width: 1600, height: 1000, bitsPerComponent: 8, bytesPerRow: 6400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1000))
            let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            fixture.board.clearContents(); fixture.board.setData(png, forType: .png)
            fixture.history.poll(); await fixture.history.flush()
            var realImages: [WeakPreviewImage] = [], fullRequests = 0
            let loader: ClipboardHistoryWindow.PreviewLoader = { id, pixels, completion in
                if pixels > 80 { fullRequests += 1 }
                fixture.history.loadPreview(id, maximumPixelSize: pixels) { value in
                    if pixels > 80, let cg = value?.image, cg.width > 80 { realImages.append(WeakPreviewImage(cg)) }
                    completion(value)
                }
            }
            let window = shortProof ? ClipboardHistoryWindow(history: fixture.history, previewIdleDelay: 0.12, previewLoader: loader)
                : ClipboardHistoryWindow(history: fixture.history, previewLoader: loader)
            defer { window.close() }
            _ = open(window); await fixture.history.flush()
            let loaded = realImages.filter { $0.image != nil }.count
            check(autoreleasepool { loaded > 0 && image(window).image != nil }, "the production ImageIO path loads synthetic large previews")
            window.dismiss()
            check(!window.isVisible, "the real-image idle fixture starts with its picker hidden")
            let started = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: shortProof ? 250_000_000 : 61_000_000_000)
            print("Remaining real image widths:", realImages.compactMap { $0.image?.width }, "displayed image present:", image(window).image != nil, "window visible:", window.isVisible)
            check(realImages.allSatisfy { $0.image == nil } && image(window).image == nil,
                  "\(shortProof ? "the short idle deadline" : "the production 60-second deadline") releases real large ImageIO preview objects")
            let before = fullRequests, opening = open(window)
            check(table(window).numberOfRows > 0 && fullRequests == before + 1,
                  "reopening after the real deadline presents the list and starts one fresh full preview")
            await fixture.history.flush()
            check(image(window).image != nil, "the original stored image still reloads after real idle reclamation")
            print(String(format: "\(shortProof ? "Short" : "Default") idle proof: %.2f seconds elapsed; reopening %.2f ms", ProcessInfo.processInfo.systemUptime - started, opening))
            if failures > 0 { exit(1) }
            print("\(shortProof ? "Short real-image proof" : "Default 60-second proof") passed with real ImageIO and isolated history")
            return
        }

        let fixture = PreviewFixture(); try await fixture.prepare(); defer { fixture.cleanup() }
        let window = fixture.window(); defer { window.close() }
        _ = open(window); primeThumbnails(window)
        select(fixture.firstImageID, in: window, history: fixture.history)
        select(fixture.textID, in: window, history: fixture.history)
        select(fixture.latestImageID, in: window, history: fixture.history)
        let largeRequests = fixture.probe.largeRequests, thumbnailRequests = fixture.probe.thumbnailRequests
        let textRequests = fixture.probe.textRequests
        check(fixture.probe.liveLargeImages == 2, "the fixture holds two independently backed large previews")
        window.dismiss(); let warmOpen = open(window)
        check(fixture.probe.largeRequests == largeRequests, "a quick reopen reuses the warm large previews")
        window.dismiss(); try await idle()
        check(fixture.probe.liveLargeImages == 0 && image(window).image == nil,
              "hidden idle expiry releases both cached image backing stores and the displayed image")
        fixture.probe.delayLargeImages = true
        let reclaimedOpen = open(window); primeThumbnails(window)
        let primary = all(window.contentView!).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "使用选中的剪贴板内容" }!
        check(table(window).numberOfRows >= 3 && primary.isEnabled && fixture.probe.pendingCount > 0,
              "reopening after reclamation presents the list and actions before the large decoder completes")
        // NSImage representations are rasterized at the display scale; its logical size identifies the source here.
        check(image(window).image != nil && image(window).image!.size.width <= 80
              && fixture.probe.thumbnailRequests == thumbnailRequests,
              "the retained small thumbnail appears immediately without decoding or loading it again")
        check(reclaimedOpen < max(50, warmOpen * 3), "a reclaimed picker opens within the same short native UI budget as a warm picker")
        var actions: [ClipboardPrimaryAction] = []
        window.onAction = { actions.append($0) }
        let search = all(window.contentView!).compactMap { $0 as? NSSearchField }.first!
        _ = window.control(search, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        await fixture.history.flush()
        for _ in 0..<100 { if !actions.isEmpty { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        check(actions == [.paste] && fixture.board.data(forType: .png) == fixture.latestPNG,
              "Return can request an exact original-image paste while its large preview is still pending")
        _ = open(window); fixture.probe.finishPending()
        check(image(window).image?.size.width == 1200,
              "the background completion replaces the thumbnail with its full preview")
        _ = open(window); select(fixture.textID, in: window, history: fixture.history)
        window.dismiss(); try await idle()
        _ = open(window); select(fixture.textID, in: window, history: fixture.history)
        check(fixture.probe.textRequests == textRequests, "idle image reclamation preserves cached text previews")
        check(fixture.history.entries.count == 3 && fixture.history.entries.first { $0.id == fixture.latestImageID }?.pinned == true
              && fixture.defaults.data(forKey: "captureShortcuts.v1") == Data("fixture-shortcuts".utf8)
              && fixture.defaults.data(forKey: "translationSettings.v1") == Data("fixture-translation-settings".utf8),
              "reclamation preserves history, pins, shortcuts and translation settings")
        window.close()

        let late = PreviewFixture(); try await late.prepare(); defer { late.cleanup() }
        late.probe.delayLargeImages = true
        let lateWindow = late.window(); defer { lateWindow.close() }
        _ = open(lateWindow); primeThumbnails(lateWindow)
        check(late.probe.largeRequests == 1, "initializing then immediately opening does not decode the same pending preview twice")
        lateWindow.dismiss(); try await idle(); late.probe.finishPending()
        check(late.probe.liveLargeImages == 0 && image(lateWindow).image == nil,
              "a decoder completion after idle expiry cannot refill or redisplay reclaimed images")
        let before = late.probe.largeRequests
        _ = open(lateWindow)
        check(late.probe.largeRequests == before + 1 && late.probe.pendingCount == 1,
              "the next opening restarts exactly one full preview after a stale completion was discarded")
        late.probe.finishPending(); lateWindow.dismiss(); _ = open(lateWindow); try await idle()
        check(late.probe.liveLargeImages == 1 && image(lateWindow).image != nil,
              "reopening cancels the old idle deadline and never clears a visible preview")
        lateWindow.orderOut(nil); try await idle()
        check(late.probe.liveLargeImages == 0, "hiding through orderOut also arms idle reclamation")
        _ = open(lateWindow); late.probe.finishPending()
        lateWindow.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification)); try await idle()
        check(late.probe.liveLargeImages == 0, "dismissing by clicking outside also reclaims large previews")
        _ = open(lateWindow); late.probe.finishPending(failing: true)
        let textPreview = all(lateWindow.contentView!).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "剪贴板内容预览" }!
        check(image(lateWindow).image == nil && textPreview.string.contains("无法预览"),
              "a failed background reload shows its recoverable error instead of a stale thumbnail")
        lateWindow.dismiss(); _ = open(lateWindow)
        check(late.probe.pendingCount == 1, "reopening retries a failed preview without blocking the list")
        _ = open(lateWindow); late.probe.finishPending(); lateWindow.close(); try await idle()
        check(late.probe.liveLargeImages == 0, "closing a retained picker also reclaims its large previews")
        print(String(format: "Native fixture opening: warm %.2f ms; after reclamation %.2f ms", warmOpen, reclaimedOpen))
        if failures > 0 { print("\(failures) preview cache checks failed"); exit(1) }
        print("Preview cache checks passed with weak image-lifetime probes and a private pasteboard; no native paste events posted")
    }
}
