// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation
import AppKit
import ImageIO
import AVFoundation
import QueCore
import CryptoKit

/// Tests that contact Pinterest run only with QUE_LIVE_TESTS=1 (release.sh sets it): every run counts against
/// Pinterest's request limit, and repeated dev runs hit it.
let runLiveTests = ProcessInfo.processInfo.environment["QUE_LIVE_TESTS"] == "1"
if !runLiveTests { print("ℹ️ Live Pinterest checks skipped (QUE_LIVE_TESTS=1 to run them)") }

func createMockPNGData() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 20,
        pixelsHigh: 20,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 20 * 4,
        bitsPerPixel: 32
    )!
    
    // Fill with solid color pixels
    if let data = rep.bitmapData {
        for i in 0..<(20 * 20 * 4) {
            data[i] = (i % 4 == 3) ? 255 : UInt8((i * 13) % 256)
        }
    }
    
    return rep.representation(using: .png, properties: [:])!
}

func testQueueAddAndClear() {
    print("Running testQueueAddAndClear...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }

    assert(queueManager.count == 0, "Queue should initially be empty")
    assert(queueManager.isEmpty, "Queue isEmpty should be true")

    let pngData = createMockPNGData()

    guard let item1 = queueManager.add(imageData: pngData, extension: "png") else {
        fatalError("Failed to add item 1")
    }
    assert(queueManager.count == 1, "Queue count should be 1")
    assert(FileManager.default.fileExists(atPath: item1.fileURL.path), "File should exist on disk")

    guard let item2 = queueManager.add(imageData: pngData, extension: "png") else {
        fatalError("Failed to add item 2")
    }
    assert(queueManager.count == 2, "Queue count should be 2")
    assert(FileManager.default.fileExists(atPath: item2.fileURL.path), "Item 2 should exist on disk")

    queueManager.clear()
    assert(queueManager.count == 0, "Queue should be empty after clear")
    assert(queueManager.isEmpty, "Queue isEmpty should be true after clear")
    print("✅ testQueueAddAndClear passed!")
}

func testPasteboardWriterPayload() {
    print("Running testPasteboardWriterPayload...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }

    let pngData = createMockPNGData()

    _ = queueManager.add(imageData: pngData, extension: "png")
    _ = queueManager.add(imageData: pngData, extension: "png")

    assert(queueManager.count == 2, "Queue count must be 2")

    let written = PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
    assert(written, "PasteboardWriter should succeed")

    let pb = NSPasteboard.general
    let items = pb.pasteboardItems
    assert(items?.count == 2, "Pasteboard should contain 2 items")

    if let filenames = pb.propertyList(forType: .init("NSFilenamesPboardType")) as? [String] {
        assert(filenames.count == 2, "Legacy filenames array should contain 2 items")
    } else {
        fatalError("NSFilenamesPboardType property missing")
    }

    print("✅ testPasteboardWriterPayload passed!")
}

func testDragPasteboard() {
    print("Running testDragPasteboard...")
    let tempURL = URL(fileURLWithPath: "/tmp/cursor_deck_test_drag.png")
    let tempURL2 = URL(fileURLWithPath: "/tmp/cursor_deck_test_drag2.png")
    try? createMockPNGData().write(to: tempURL)
    try? createMockPNGData().write(to: tempURL2)
    defer {
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL2)
    }

    // Same payload DeckHUDView builds for a drag: one NSURL per item.
    let pboard = NSPasteboard(name: .drag)
    pboard.clearContents()
    pboard.writeObjects([tempURL as NSURL, tempURL2 as NSURL])
    assert(pboard.pasteboardItems?.count == 2, "Drag pasteboard should carry one item per deck image")
    let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    assert(urls.map(\.path) == [tempURL.path, tempURL2.path], "Drag pasteboard should list the deck files in order")
    print("✅ testDragPasteboard passed!")
}

func testHUDPanelLifecycle() {
    print("Running testHUDPanelLifecycle...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }

    let panel = CursorHUDPanel(queueManager: queueManager)
    panel.startTracking()
    defer { panel.stopTracking() }

    assert(!panel.isVisible, "Panel should be hidden when queue is empty")

    let pngData = createMockPNGData()
    _ = queueManager.add(imageData: pngData, extension: "png")

    // Pump main runloop briefly to process observer
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    print("   Panel isVisible after item add:", panel.isVisible)
    print("   Panel frame:", panel.frame)
    print("   Panel level:", panel.level.rawValue)
    print("   Panel isFloatingPanel:", panel.isFloatingPanel)

    assert(panel.isVisible, "Panel should become visible when item is added")

    // Paused tracking: the pill stays visible but lets every click through; resuming takes clicks again.
    panel.isTrackingPaused = true
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    assert(panel.isVisible && panel.ignoresMouseEvents, "Paused pill stays visible and passes clicks through")
    let pill = panel.contentView as! DeckHUDView
    assert(pill.isPaused, "Paused pill shows the orange dot")
    assert((pill.accessibilityValue() as? String) == "Paused, 1 item", "VoiceOver hears it's paused")
    panel.isSuspended = true; panel.isSuspended = false   // board picker open/close while paused
    assert(panel.ignoresMouseEvents, "Still click-through after the board picker closes while paused")
    panel.isTrackingPaused = false
    assert(!panel.ignoresMouseEvents, "Resumed pill takes clicks again")
    assert(!pill.isPaused && (pill.accessibilityValue() as? String) == "1 item", "Resumed: green dot, plain count")

    queueManager.clear()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))

    assert(!panel.isVisible, "Panel should hide when queue is cleared")
    print("✅ testHUDPanelLifecycle passed!")
}

func testPinterestMediaResolverURLDetection() {
    print("Running testPinterestMediaResolverURLDetection...")
    let resolver = PinterestMediaResolver.shared
    assert(resolver.isPinterestURL("https://pin.it/7x3FcJ9B0"), "pin.it should be recognized")
    assert(resolver.isPinterestURL("https://www.pinterest.com/pin/664281013778109217/"), "canonical pin URL should be recognized")
    assert(resolver.isPinterestURL("https://in.pinterest.com/pin/12345/"), "localized pin URL should be recognized")
    assert(!resolver.isPinterestURL("https://google.com"), "google should not be recognized")
    assert(!resolver.isPinterestURL("https://github.com/pin"), "github should not be recognized")

    // Test robust Pin ID extraction
    let id1 = resolver.extractPinId(from: "https://www.pinterest.com/pin/664281013778109217/")
    assert(id1 == "664281013778109217", "Should extract id from canonical URL")

    let id2 = resolver.extractPinId(from: "https://www.pinterest.com/pin/venus-motion-design-664281013778109217/")
    assert(id2 == "664281013778109217", "Should extract id from slugged single dash URL")

    let id3 = resolver.extractPinId(from: "https://www.pinterest.com/pin/origami--664281013778109217/?invite_code=xyz")
    assert(id3 == "664281013778109217", "Should extract id with double dash and query params")

    let id4 = resolver.extractPinId(from: "https://in.pinterest.com/pin/664281013778109217/sent/?invite_code=abc")
    assert(id4 == "664281013778109217", "Should extract id with subpaths")
    print("✅ testPinterestMediaResolverURLDetection passed!")
}

func testPinterestLiveVideoResolution() {
    print("Running testPinterestLiveVideoResolution...")
    let semaphore = DispatchSemaphore(value: 0)
    var resolvedResult: PinterestMediaResult?

    PinterestMediaResolver.shared.resolveMedia(from: "https://www.pinterest.com/pin/664281013778109217/") { res in
        resolvedResult = res
        semaphore.signal()
    }

    _ = semaphore.wait(timeout: .now() + 10.0)

    // No answer = offline or Pinterest is down: a network condition, so it must not block a release.
    guard let result = resolvedResult else {
        print("   ⚠️ Pinterest didn't answer; skipping the live pin checks")
        return
    }

    switch result {
    case .video(let videoURL):
        print("   Direct video pin resolved to stream URL:", videoURL)
        assert(videoURL.absoluteString.contains("pinimg.com/videos/"), "Must be a direct Pinterest CDN video URL")
    case .image(let imageURL):
        fatalError("Video pin should NEVER resolve to an image: \(imageURL)")
    case .board:
        fatalError("A pin URL should never resolve to a board")
    case .rateLimited:
        print("   ⚠️ Pinterest rate-limited this run; skipping the live pin check (network condition, not code)")
    }

    // Also test Story Pin resolution (pin with HLS / Idea pin)
    let sem2 = DispatchSemaphore(value: 0)
    var storyResult: PinterestMediaResult?
    PinterestMediaResolver.shared.resolveMedia(from: "https://www.pinterest.com/pin/593912269657451880/") { res in
        storyResult = res
        sem2.signal()
    }
    _ = sem2.wait(timeout: .now() + 10.0)
    guard let sRes = storyResult else {
        print("   ⚠️ Pinterest didn't answer; skipping the live story pin check")
        return
    }
    switch sRes {
    case .video(let videoURL):
        print("   Story/Idea video pin resolved to stream URL:", videoURL)
        assert(videoURL.absoluteString.contains("pinimg.com/videos/"), "Must be a valid video stream")
    case .image(let imageURL):
        fatalError("Story video pin should NEVER resolve to an image: \(imageURL)")
    case .board:
        fatalError("A pin URL should never resolve to a board")
    case .rateLimited:
        print("   ⚠️ Pinterest rate-limited this run; skipping the live story pin check")
    }

    print("✅ testPinterestLiveVideoResolution passed!")
}

func testPinterestBoardURLDetection() {
    print("Running testPinterestBoardURLDetection...")
    let r = PinterestBoardResolver.shared
    let boards: [(String, String, String)] = [
        ("https://www.pinterest.com/thandisibanda1984/sexy-cars/", "thandisibanda1984", "sexy-cars"),
        ("https://in.pinterest.com/someone/brand-refs", "someone", "brand-refs"),
        ("https://www.pinterest.co.uk/someone/type/?invite_code=abc", "someone", "type"),
        ("  https://pinterest.com/someone/motion/  ", "someone", "motion"),
    ]
    for (url, user, slug) in boards {
        guard let ref = r.boardReference(from: url) else { fatalError("Should be a board: \(url)") }
        assert(ref.username == user && ref.slug == slug, "Wrong board parsed from \(url)")
    }
    let notBoards = [
        "https://www.pinterest.com/pin/664281013778109217/",       // a pin
        "https://www.pinterest.com/someone/",                       // a profile
        "https://www.pinterest.com/someone/_saved/",                // profile tab
        "https://www.pinterest.com/someone/boards/",                // profile tab
        "https://www.pinterest.com/search/pins/?q=chairs",          // search
        "https://www.pinterest.com/ideas/chairs/123456/",           // ideas page (3 parts)
        "https://www.pinterest.com/someone/board/section/",         // board section (not supported yet)
        "https://pin.it/7x3FcJ9B0",                                 // short link: resolved later, not here
        "https://example.com/someone/board/",                       // not Pinterest
        "https://notpinterest.com/someone/board/",
    ]
    for url in notBoards { assert(r.boardReference(from: url) == nil, "Should NOT be a board: \(url)") }
    print("✅ testPinterestBoardURLDetection passed!")
}

func testPillNoticeWording() {
    print("Running testPillNoticeWording...")
    let limited = PillNotice.pinterestRateLimited(retryAfter: nil)
    assert(limited.message == "Pinterest is limiting requests", "Rate limit names Pinterest, not the user")
    assert(limited.detail?.contains("few minutes") == true, "Rate limit must say when to retry")
    assert(PillNotice.pinterestRateLimited(retryAfter: 30).detail == "Try again in about a minute.")
    assert(PillNotice.pinterestRateLimited(retryAfter: 150).detail == "Try again in about 3 minutes.")
    let partial = PillNotice.pinterestRateLimited(retryAfter: nil, partial: (12, 48, "Added"))
    assert(partial.detail?.hasPrefix("Added 12 of 48.") == true, "Partial rate limit must report progress")
    assert(PillNotice.boardOffer(name: "Refs", pinCount: 512, cap: 100, addAll: {}, choose: {}).detail?
        .contains("first 100") == true, "Big boards must say only the first 100 are added")
    var chose = false, addedAll = false
    let offer = PillNotice.boardOffer(name: "Refs", pinCount: 48, cap: 100, addAll: { addedAll = true }, choose: { chose = true })
    offer.primaryAction?()
    assert(chose && !addedAll, "⌥-click on a board offer opens the picker")
    offer.alternateAction?()
    assert(addedAll, "⌥-click and hold on a board offer adds the batch")
    assert(PillNotice.boardAdded(added: 45, requested: 48, name: "Refs").tone == .warning)
    assert(PillNotice.boardAdded(added: 3, requested: 3, name: "Refs").duration == 2, "Plain confirmation is brief")
    let prep = PillNotice.boardPreparing(name: "Refs")
    assert(prep.duration == nil && prep.message.hasSuffix("is joining Que"), "⌘-click turns the offer into progress that stays until done")
    assert(PillNotice.boardOnPrivateProfile().message == "This board is on a private profile")
    // The notice shows its detail on one line and cuts it at 260 pt (DeckHUDView.noticeMaxTextWidth): keep these whole.
    for notice in [PillNotice.boardNotFound(), PillNotice.boardOnPrivateProfile()] {
        let width = (notice.detail! as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        assert(width <= 250, "Notice detail would be cut off (\(Int(width)) pt): \(notice.detail!)")
    }
    let again = PillNotice.boardAlreadyAdded(name: "Refs", choose: {})
    assert(again.message == "“Refs” is already in Que" && again.alternateAction != nil && again.primaryAction == nil,
           "Re-copied board: says so, ⌥-click opens the picker, nothing is added again")
    assert(PillNotice.boardAdded(added: 5, requested: 5, name: "Refs", alreadyInDeck: 20).detail == "20 pins were already in Que.")
    print("✅ testPillNoticeWording passed!")
}

func testBoardPickerSelection() {
    print("Running testBoardPickerSelection...")
    let board = PinterestBoard(id: "1", name: "Test", pinCount: 7, username: "u", slug: "s")
    func pin(_ n: Int) -> PinterestBoardPin {
        let u = URL(string: "https://i.pinimg.com/236x/\(n).jpg")!
        return PinterestBoardPin(id: "\(n)", title: nil, thumbnailURL: u, imageURL: u, videoURL: nil, dominantColor: nil)
    }
    let model = BoardPickerModel(board: board)
    model.appendPage((1...5).map(pin), nextBookmark: "next")
    assert(model.selection.count == 5 && model.allSelected, "Pins start selected")
    assert(model.hasMore, "A bookmark means more pages")
    model.toggle(pin(2))
    assert(!model.selection.contains("2"), "Click deselects")
    model.toggle(pin(4), extendingRange: true)                  // Shift-click: 2...4 take pin 4's new state (off)
    assert(model.selection == ["1", "5"], "Shift-click applies to the range, got \(model.selection.sorted())")
    model.selectNone()
    model.appendPage([pin(6), pin(7), pin(1)], nextBookmark: nil)   // duplicate pin 1 is ignored
    assert(model.pins.count == 7 && model.selection.isEmpty, "After Select None, new pins arrive unselected")
    assert(!model.hasMore, "No bookmark means the board is fully loaded")
    model.selectAll()
    assert(model.selectedPins.map(\.id) == (1...7).map(String.init), "Select All keeps board order")
    // Sections: images first, then video pins (GIFs); Shift-click ranges follow that on-screen order.
    func video(_ n: Int) -> PinterestBoardPin {
        let u = URL(string: "https://i.pinimg.com/236x/\(n).jpg")!
        return PinterestBoardPin(id: "v\(n)", title: nil, thumbnailURL: u, imageURL: u, videoURL: URL(string: "https://v.pinimg.com/\(n).mp4"), dominantColor: nil)
    }
    let mixed = BoardPickerModel(board: board)
    mixed.appendPage([pin(1), video(2), pin(3), video(4)], nextBookmark: nil)
    assert(mixed.displayPins.map(\.id) == ["1", "3", "v2", "v4"], "Images first, then GIFs, got \(mixed.displayPins.map(\.id))")
    mixed.selectNone()
    mixed.toggle(pin(3))
    mixed.toggle(video(2), extendingRange: true)
    assert(mixed.selection == ["3", "v2"], "Range follows on-screen order, got \(mixed.selection.sorted())")
    model.setPinsInDeck(["3", "6"])
    assert(!model.selection.contains("3") && !model.selection.contains("6"), "Pins already in the deck start unselected")
    model.toggle(pin(3))
    assert(model.selection.contains("3"), "...but can still be chosen on purpose")
    model.appendPage([pin(8)], nextBookmark: nil)
    assert(model.selection.contains("8"), "New pins not in the deck still arrive selected")
    print("✅ testBoardPickerSelection passed!")
}

func testPillNoticeShowsAndHides() {
    print("Running testPillNoticeShowsAndHides...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let panel = CursorHUDPanel(queueManager: queueManager)
    assert(!panel.isVisible, "Empty deck: pill hidden")
    let notice = PillNotice.pinterestRateLimited(retryAfter: nil)
    panel.show(notice)
    assert(panel.isVisible, "A notice shows the pill even with an empty deck")
    let expected = (panel.contentView as! DeckHUDView).preferredSize(for: notice)
    // Let the size animation settle (up to 1.5s: it runs slower while the machine is busy).
    let settleBy = Date().addingTimeInterval(1.5)
    while Date() < settleBy && (abs(panel.frame.width - expected.width) > 1 || abs(panel.frame.height - expected.height) > 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    assert(abs(panel.frame.width - expected.width) <= 1 && abs(panel.frame.height - expected.height) <= 1,
           "Pill grows to fit the notice: \(panel.frame.size) vs \(expected)")
    assert(expected.height == 42, "Two-line notice is 42pt tall")
    panel.dismissNotice()
    assert(panel.isVisible, "The pill collapses back to its dot before hiding")
    RunLoop.current.run(until: Date().addingTimeInterval(0.6))
    assert(!panel.isVisible, "After collapsing, an empty deck hides the pill")
    print("✅ testPillNoticeShowsAndHides passed!")
}

func testScreenshotOverlayDetection() {
    print("Running testScreenshotOverlayDetection...")
    // Seen on macOS 27 while taking ⌘⇧4 / ⌘⇧5 screenshots (window owner, layer)
    assert(CursorHUDPanel.isScreenshotWindow(ownerName: "screencapture", bundleID: nil, layer: 1498), "⌘⇧4 selection overlay")
    assert(CursorHUDPanel.isScreenshotWindow(ownerName: "Bildschirmfoto", bundleID: "com.apple.screencaptureui", layer: 1499),
           "⌘⇧5 toolbar, matched by bundle id whatever the language")
    assert(!CursorHUDPanel.isScreenshotWindow(ownerName: "Screenshot", bundleID: "com.apple.screencaptureui", layer: 24),
           "The post-capture thumbnail (low layer) is not the overlay")
    assert(!CursorHUDPanel.isScreenshotWindow(ownerName: "Google Chrome", bundleID: "com.google.Chrome", layer: 0))
    assert(!CursorHUDPanel.isScreenshotWindow(ownerName: "Dock", bundleID: "com.apple.dock", layer: 20))
    print("✅ testScreenshotOverlayDetection passed!")
}

func testBackgroundImport() {
    print("Running testBackgroundImport...")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cd-import-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    // 40x20 image saved as HEIC with "rotate 90°" stored as metadata (like an iPhone photo), plus a TIFF and a PNG.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let heic = dir.appendingPathComponent("photo.heic"), tiff = dir.appendingPathComponent("scan.tiff"), png = dir.appendingPathComponent("plain.png")
    let dest = CGImageDestinationCreateWithURL(heic as CFURL, "public.heic" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, rep.cgImage!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    assert(CGImageDestinationFinalize(dest), "test HEIC written")
    try! rep.tiffRepresentation!.write(to: tiff)
    try! rep.representation(using: .png, properties: [:])!.write(to: png)

    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    var added: [DeckItem]?
    let returnedAt = CACurrentMediaTime()
    queueManager.addFiles([heic, tiff, png]) { added = $0 }
    assert(added == nil, "Import must not finish synchronously (it runs off the main thread)")
    _ = returnedAt
    let deadline = Date().addingTimeInterval(10)
    while added == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    guard let items = added else { fatalError("Background import timed out") }
    assert(items.count == 3 && queueManager.count == 3, "All three files added")
    assert(items.map { $0.fileURL.pathExtension } == ["png", "png", "png"], "HEIC and TIFF become PNG; order kept")
    assert(items.map { $0.originalFileName } == ["photo.heic", "scan.tiff", "plain.png"], "Copy order is preserved")
    let first = CGImageSourceCreateWithURL(items[0].fileURL as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
    assert(first?[kCGImagePropertyPixelWidth] as? Int == 20 && first?[kCGImagePropertyPixelHeight] as? Int == 40,
           "Phone-photo rotation is applied (40x20 rotated 90° → 20x40)")
    print("✅ testBackgroundImport passed!")
}

/// Deck preview multi-select: removing several images is one queue change, keeps order, and deletes the files.
func testRemoveSeveralItems() {
    print("Running testRemoveSeveralItems...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let items = (0..<5).compactMap { _ in queueManager.add(imageData: createMockPNGData(), extension: "png") }
    assert(items.count == 5, "Should add 5 items")

    RunLoop.current.run(until: Date().addingTimeInterval(0.1))   // let the five "added" updates go out first
    var notifications = 0
    queueManager.addObserver { _ in notifications += 1 }
    queueManager.remove(ids: [items[1].id, items[3].id])
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))

    assert(queueManager.items.map { $0.id } == [items[0].id, items[2].id, items[4].id], "Remaining items keep their order")
    assert(!FileManager.default.fileExists(atPath: items[1].fileURL.path), "Removed file 1 should be deleted")
    assert(!FileManager.default.fileExists(atPath: items[3].fileURL.path), "Removed file 3 should be deleted")
    assert(FileManager.default.fileExists(atPath: items[2].fileURL.path), "Kept file should stay")
    assert(notifications == 1, "One refresh for the whole removal, got \(notifications)")

    queueManager.remove(ids: [UUID()])   // unknown id: no change, no refresh
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    assert(notifications == 1 && queueManager.count == 3, "Unknown ids change nothing")
    print("✅ testRemoveSeveralItems passed!")
}

/// CursorDeck → Que: the bundle renames itself once, and only when it's safe.
func testLegacyAppRename() {
    print("Running testLegacyAppRename...")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("que-rename-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    let legacy = dir.appendingPathComponent("CursorDeck.app")
    try? fm.createDirectory(at: legacy.appendingPathComponent("Contents"), withIntermediateDirectories: true)

    assert(LegacyAppRename.targetPath(for: "/Applications/Que.app") == nil, "Que.app is left alone")
    assert(LegacyAppRename.targetPath(for: "/Applications/Other.app") == nil, "Other apps are left alone")
    let renamed = LegacyAppRename.renameIfNeeded(bundlePath: legacy.path)
    assert(renamed == dir.appendingPathComponent("Que.app").path, "CursorDeck.app becomes Que.app")
    assert(fm.fileExists(atPath: dir.appendingPathComponent("Que.app/Contents").path) && !fm.fileExists(atPath: legacy.path),
           "Bundle contents moved")

    // A Que.app already there (e.g. installed from the DMG): never overwrite it.
    try? fm.createDirectory(at: legacy, withIntermediateDirectories: true)
    assert(LegacyAppRename.renameIfNeeded(bundlePath: legacy.path) == nil, "Existing Que.app is not replaced")
    assert(fm.fileExists(atPath: legacy.path), "CursorDeck.app stays when Que.app exists")
    print("✅ testLegacyAppRename passed!")
}

/// CursorDeck 1.x's Login Item is replaced by Que's, keeping whether it was on.
func testLoginItemMigration() {
    print("Running testLoginItemMigration...")
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("que-agents-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: dir) }
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let legacy = dir.appendingPathComponent("com.cursordeck.app.plist")

    let off = LaunchAtLoginManager(launchAgentsDirectory: dir)
    off.migrateLegacyAgent()
    assert(!off.isEnabled, "No old Login Item: stays off")

    try? "<plist/>".write(to: legacy, atomically: true, encoding: .utf8)
    let on = LaunchAtLoginManager(launchAgentsDirectory: dir)
    on.migrateLegacyAgent()
    assert(on.isEnabled && !fm.fileExists(atPath: legacy.path), "Old Login Item replaced by Que's")
    let plist = NSDictionary(contentsOf: dir.appendingPathComponent("com.que.app.login.plist"))
    assert((plist?["ProgramArguments"] as? [String])?.first == on.appExecutablePath, "Opens Que")
    print("✅ testLoginItemMigration passed!")
}

/// Update dot: the dot-less menu bar mark loads at 1x and 2x, and the dot sits inside the 16pt mark.
func testUpdateDotAssets() {
    print("Running testUpdateDotAssets...")
    let image = QueLogoAsset.menuBarImageWithoutDot
    assert(image.isTemplate && image.representations.map { $0.pixelsWide }.sorted() == [16, 32], "Dot-less mark has 1x and 2x")
    let dot = QueLogoAsset.updateDotRect
    assert(dot.minX >= 0 && dot.maxX <= 16 && dot.minY >= 0 && dot.maxY <= 16.01, "Dot sits inside the 16pt mark")
    print("✅ testUpdateDotAssets passed!")
}

/// The welcome shows for any copy installed by hand (new or returning users), not after updates or on relaunch.
func testWelcomeOnFreshInstalls() {
    print("Running testWelcomeOnFreshInstalls...")
    let suite = "com.que.tests.welcome.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    d.set(1_700_000_000.0, forKey: "CursorDeck_lastBackgroundCheck")   // a returning CursorDeck user

    assert(WelcomeWindowController.shouldShowWelcome(copyID: "100", defaults: d), "Installed from the DMG: welcome")
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "100", defaults: d), "Same copy opened again: no welcome")
    d.set(true, forKey: WelcomeWindowController.updateInProgressKey)
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "200", defaults: d), "New copy from an in-app update: no welcome")
    assert(d.object(forKey: WelcomeWindowController.updateInProgressKey) == nil, "Update note cleared")
    assert(WelcomeWindowController.shouldShowWelcome(copyID: "300", defaults: d), "Deleted and reinstalled: welcome again")
    d.set(true, forKey: WelcomeWindowController.updateInProgressKey)   // an update that failed (old copy reopened)
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "300", defaults: d), "Failed update: no welcome")
    assert(WelcomeWindowController.shouldShowWelcome(copyID: "400", defaults: d), "...and the note doesn't linger")
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: nil, defaults: d), "Development builds: never")

    // Installed before the "How should Que come to you?" choice: the first update shows the welcome once.
    let suite2 = "com.que.tests.welcome2.\(UUID().uuidString)"
    let old = UserDefaults(suiteName: suite2)!
    defer { old.removePersistentDomain(forName: suite2) }
    old.set("10", forKey: "Que_lastLaunchedCopy")
    old.set(true, forKey: WelcomeWindowController.updateInProgressKey)
    assert(WelcomeWindowController.shouldShowWelcome(copyID: "11", defaults: old), "First update with the choice: welcome once")
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "11", defaults: old), "Then normal launches: none")
    old.set(true, forKey: WelcomeWindowController.updateInProgressKey)
    assert(!WelcomeWindowController.shouldShowWelcome(copyID: "12", defaults: old), "Later updates: none")
    print("✅ testWelcomeOnFreshInstalls passed!")
}

/// Video → GIF / pin jobs: the ticket ends exactly once, a dropped one counts as failed, and Que stays on screen
/// (as just the dot when empty) while working.
func testWorkingIndicator() {
    print("Running testWorkingIndicator...")
    var outcomes: [WorkTicket.Outcome] = []
    let a = WorkTicket(isVideo: true) { outcome, _ in outcomes.append(outcome) }
    a.finish(.added); a.finish(.failed)
    assert(outcomes == [.added], "A job ends once")
    var dropped: WorkTicket? = WorkTicket(isVideo: false) { outcome, isVideo in
        outcomes.append(outcome); assert(!isVideo)
    }
    _ = dropped; dropped = nil
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    assert(outcomes == [.added, .failed], "A job dropped without ending counts as failed (no stuck dot)")

    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let panel = CursorHUDPanel(queueManager: queueManager)
    panel.isWorking = true
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    assert(panel.isVisible, "Working on an empty Que: still on screen")
    assert(abs(panel.frame.width - 28) <= 1, "...as just the 28pt dot, got \(panel.frame.size)")
    assert((panel.contentView as! DeckHUDView).isWorking, "Dot is in its working state")
    panel.isWorking = false
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    assert(!panel.isVisible, "Done and still empty (e.g. cancelled): hidden again")
    assert(PillNotice.makingGIF().message == "Making a GIF" && PillNotice.makingGIF().detail == "Saving it a spot in Que.", "Wording")
    print("✅ testWorkingIndicator passed!")
}

func testControlDoubleTap() {
    print("Running testControlDoubleTap...")
    // Feeds (⌃ down?, time) polls; `keyAt` = when the last other key/click happened.
    func run(_ polls: [(Bool, TimeInterval)], others: Bool = false, keyAt: TimeInterval = -100) -> Bool {
        var d = ControlDoubleTap()
        var fired = false
        for (down, t) in polls {
            if d.update(controlDown: down, otherModifiers: others, secondsSinceKeyOrClick: t - keyAt, now: t) { fired = true }
        }
        return fired
    }
    let quick: [(Bool, TimeInterval)] = [(false, 0), (true, 0.1), (false, 0.2), (true, 0.4), (false, 0.5)]
    assert(run(quick), "Two quick taps fire")
    assert(!run(Array(quick.prefix(3))), "One tap doesn't")
    assert(!run([(false, 0), (true, 0.1), (false, 0.2), (true, 0.7), (false, 0.8)]), "Taps too far apart")
    assert(!run([(false, 0), (true, 0.1), (false, 0.6), (true, 0.7), (false, 0.8)]), "A held ⌃ (⌃-click) isn't a tap")
    assert(!run(quick, keyAt: 0.3), "⌃C ⌃C: a key between the taps cancels")
    assert(!run(quick, keyAt: 0.45), "A key during the second tap cancels")
    assert(!run(quick, others: true), "⌃ with another modifier isn't a tap")
    var d = ControlDoubleTap(); var fires = 0
    for (down, t) in quick + quick.map({ ($0.0, $0.1 + 0.9) }) + quick.map({ ($0.0, $0.1 + 1.8) }) {
        if d.update(controlDown: down, otherModifiers: false, secondsSinceKeyOrClick: 100, now: t) { fires += 1 }
    }
    assert(fires == 3, "Each double-tap fires once (toggle on, off, on), got \(fires)")
    print("✅ testControlDoubleTap passed!")
}

/// Board offer: a short ⌥-click chooses pins; holding the click adds the whole board, once, and the shake that marks
/// the hold stays on its anchor and always comes to rest (let go early, held through, or dragged away).
func testHoldAddsWholeBoard() {
    print("Running testHoldAddsWholeBoard...")
    let view = DeckHUDView(frame: NSRect(x: 0, y: 0, width: 220, height: 42))
    let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 220, height: 42), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = view
    defer { window.close() }
    let anchor = window.frame.origin
    var chose = 0, added = 0
    view.setNotice(.boardOffer(name: "B", pinCount: 5, cap: 100, addAll: { added += 1 }, choose: { chose += 1 }))
    func mouse(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = .option) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    var maxDrift: CGFloat = 0
    func run(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            maxDrift = max(maxDrift, abs(window.frame.origin.x - anchor.x))
            assert(window.frame.origin.y == anchor.y, "The shake is side to side only")
        }
    }
    func hold(_ seconds: TimeInterval) {
        view.mouseDown(with: mouse(.leftMouseDown)); run(seconds); view.mouseUp(with: mouse(.leftMouseUp)); run(0.6)
        assert(window.frame.origin == anchor, "Comes to rest exactly on its anchor")
    }

    hold(0.05)
    assert(chose == 1 && added == 0, "A short click still chooses pins")
    hold(0.5)
    assert(chose == 1 && added == 0, "Let go mid-shake: nothing runs, not even the click")
    let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    maxDrift = 0
    hold(1.2)
    assert(chose == 1 && added == 1, "Held past the threshold: the whole board is added, once, and the click doesn't run")
    // ±1.5 pt; a window off any Retina screen snaps to whole points, so up to 2.
    assert(reduceMotion ? maxDrift == 0 : (maxDrift > 0.3 && maxDrift <= 2), "Small shake, no drift: \(maxDrift)")


    // Adding swaps the offer for a notice with no choices: letting go then must not also copy everything in Que.
    let queue = DeckQueueManager()
    defer { queue.cleanup() }
    _ = queue.add(imageData: createMockPNGData(), extension: "png")
    view.queueManager = queue
    view.setNotice(.boardOffer(name: "B", pinCount: 5, cap: 100,
                               addAll: { added += 1; view.setNotice(.boardPreparing(name: "B")) }, choose: {}))
    let clipboard = NSPasteboard.general.changeCount
    view.mouseDown(with: mouse(.leftMouseDown, [])); run(1.2); view.mouseUp(with: mouse(.leftMouseUp, [])); run(0.6)
    assert(added == 2, "Held again: added once more")
    assert(NSPasteboard.general.changeCount == clipboard, "The release after a hold isn't also a click on Que")
    print("✅ testHoldAddsWholeBoard passed!")
}

func testCallStyleWording() {
    print("Running testCallStyleWording...")
    defer { UserDefaults.standard.removeObject(forKey: "Que_doubleTapControl") }
    for doubleTap in [false, true] {
        QueControls.usesDoubleTap = doubleTap
        let other = doubleTap ? "⌥-click" : "⌃"
        let notices = [PillNotice.boardOffer(name: "B", pinCount: 200, cap: 100, addAll: {}, choose: {}),
                       PillNotice.boardAlreadyAdded(name: "B", choose: {}), PillNotice.gifEditFailed()]
        for n in notices { assert(!(n.detail ?? "").contains(other), "Notice mixes ways: \(n.detail ?? "")") }
    }
    assert(PillNotice.boardOffer(name: "B", pinCount: 5, cap: 100, addAll: {}, choose: {}).detail
           == "⌃⌃ then click to choose, hold to add all", "⌃⌃ wording")
    print("✅ testCallStyleWording passed!")
}

func testPinterestWaitIsRemembered() {
    print("Running testPinterestWaitIsRemembered...")
    PinterestBoardResolver.forgetLimit()   // a refused live check in an earlier run is saved and would skew this
    defer { PinterestBoardResolver.forgetLimit() }
    let now = Date()
    PinterestBoardResolver.rememberLimit(retryAfter: 120, now: now)
    assert(abs((PinterestBoardResolver.remainingWait(now: now) ?? 0) - 120) < 0.01, "Waits as long as Pinterest says")
    PinterestBoardResolver.rememberLimit(retryAfter: 30, now: now)
    assert((PinterestBoardResolver.remainingWait(now: now) ?? 0) > 100, "A shorter answer never shortens the wait")
    assert(PinterestBoardResolver.remainingWait(now: now.addingTimeInterval(121)) == nil, "Asks again once it's over")
    PinterestBoardResolver.rememberLimit(retryAfter: nil, now: now)
    assert(abs((PinterestBoardResolver.remainingWait(now: now) ?? 0) - 300) < 0.01, "No answer: 5 minutes")
    let saved = UserDefaults.standard.object(forKey: PinterestBoardResolver.limitKey) as? Date
    assert(saved.map { abs($0.timeIntervalSince(now) - 300) < 0.01 } == true, "The wait is saved for the next launch")
    PinterestBoardResolver.forgetLimit()
    assert(UserDefaults.standard.object(forKey: PinterestBoardResolver.limitKey) == nil, "Forgetting clears the saved wait")

    // During the wait, lookups answer straight away without touching the network.
    PinterestBoardResolver.rememberLimit(retryAfter: 600)
    var board: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver().fetchBoard(username: "someone", slug: "refs") { board = $0 }
    if case .failure(.rateLimited(let wait))? = board { assert(wait! > 590, "Reports the time left") }
    else { assert(false, "Board lookup must answer 'limited' at once, got \(String(describing: board))") }
    // Single pins still ask Pinterest during a wait (not checked here: it would make a live request).
    // Image servers' own limit stops one board import only, never every Pinterest link.
    assert(PinterestBoardResolver.isImageServer(URL(string: "https://i.pinimg.com/originals/a/b.jpg")))
    assert(PinterestBoardResolver.isImageServer(URL(string: "https://v1.pinimg.com/videos/x.mp4")))
    assert(!PinterestBoardResolver.isImageServer(URL(string: "https://www.pinterest.com/resource/PinResource/get/")))
    assert(!PinterestBoardResolver.isImageServer(URL(string: "https://pin.it/abc")))

    // "Report a Problem…" says which request was refused, never which pin.
    let pinNote = PinterestBoardResolver.limitNote(
        url: URL(string: "https://www.pinterest.com/resource/PinResource/get/?source_url=/pin/664281013778109217/"),
        inBody: true, retryAfter: nil)
    assert(pinNote == "Pinterest 429 (PinResource, in reply, Retry-After none)", pinNote)
    let pageNote = PinterestBoardResolver.limitNote(url: URL(string: "https://www.pinterest.com/pin/664281013778109217/"),
                                                    inBody: false, retryAfter: "120")
    assert(pageNote == "Pinterest 429 (pin page, HTTP status, Retry-After 120)", pageNote)
    assert(PillNotice.pinterestRateLimited(retryAfter: 300).message == "Pinterest is limiting requests")
    print("✅ testPinterestWaitIsRemembered passed!")
}

func testSnapEndsWhenQueEmpties() {
    print("Running testSnapEndsWhenQueEmpties...")
    QueControls.usesDoubleTap = true
    defer { UserDefaults.standard.removeObject(forKey: "Que_doubleTapControl") }
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let panel = CursorHUDPanel(queueManager: queueManager)
    _ = queueManager.add(imageData: createMockPNGData())
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    let view = panel.contentView as! DeckHUDView
    panel.isTapSnapped = true
    assert(view.isTapSnapped, "Snapped: the badge shows it")
    queueManager.clear()
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    assert(!view.isTapSnapped, "Que emptied while snapped: the next copy must not come back snapped")
    print("✅ testSnapEndsWhenQueEmpties passed!")
}

func testBoardPageParsing() {
    print("Running testBoardPageParsing...")
    func page(sections: Int, bookmark: String, url: String = "/Someone/Brand-Refs/") -> Data {
        let pin = #"{"type":"pin","id":"11","images":{"orig":{"url":"https://i.pinimg.com/originals/a.jpg"},"236x":{"url":"https://i.pinimg.com/236x/a.jpg"}}}"#
        let props = #"{"initialReduxState":{"boards":{"77":{"id":"77","name":"Brand refs","url":"\#(url)","pin_count":105,"section_count":\#(sections)}},"resources":{"BoardFeedResource":{"k":{"data":[\#(pin),{"type":"story"}],"nextBookmark":"\#(bookmark)"}}}}}"#
        return Data(#"<html><script id="__PWS_INITIAL_PROPS__" type="application/json">\#(props)</script></html>"#.utf8)
    }
    let parsed = PinterestBoardResolver.parseBoardPage(page(sections: 0, bookmark: "abc"), username: "someone", slug: "brand-refs")
    assert(parsed?.board == PinterestBoard(id: "77", name: "Brand refs", pinCount: 105, username: "someone", slug: "brand-refs"),
           "Board info comes from the page (link case doesn't matter)")
    assert(parsed?.pins?.map(\.id) == ["11"], "First pins come from the page; non-pins are skipped")
    assert(parsed?.nextBookmark == "abc", "Keeps the bookmark for the next pins")
    assert(PinterestBoardResolver.parseBoardPage(page(sections: 0, bookmark: "-end-"), username: "someone", slug: "brand-refs")?
           .nextBookmark == nil, "-end- means no more pins")
    let sectioned = PinterestBoardResolver.parseBoardPage(page(sections: 2, bookmark: "abc"), username: "someone", slug: "brand-refs")
    assert(sectioned?.board.id == "77" && sectioned?.pins == nil, "Boards with sections load their pins the old way (keeps section pins)")
    assert(PinterestBoardResolver.parseBoardPage(Data("<html>login</html>".utf8), username: "a", slug: "b") == nil,
           "A page without board data falls back to the old lookup")
    // A page that loads but lists no boards (missing board or private profile) is told apart from a page we can't read.
    let empty = Data(#"<script id="__PWS_INITIAL_PROPS__">{"initialReduxState":{"boards":{}}}</script>"#.utf8)
    assert(PinterestBoardResolver.parseBoardPage(empty, username: "a", slug: "b") == nil && PinterestBoardResolver.boardPageIsReadable(empty),
           "Intact page without the board: ask about the profile, not BoardResource")
    assert(!PinterestBoardResolver.boardPageIsReadable(Data("<html>login</html>".utf8)), "Unreadable page: old lookup")
    assert(PinterestBoardResolver.boardPageIsReadable(page(sections: 0, bookmark: "abc")), "A normal board page is readable")
    print("✅ testBoardPageParsing passed!")
}

func testPinterestLiveBoard() {
    print("Running testPinterestLiveBoard...")
    let sem = DispatchSemaphore(value: 0)
    var boardResult: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver.shared.fetchBoard(username: "thandisibanda1984", slug: "sexy-cars") { boardResult = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    switch boardResult {
    case .failure(.rateLimited)?:
        print("   ⚠️ Pinterest rate-limited this run; skipping the live board check"); return
    case .failure(let error)?:
        fatalError("Live board lookup failed: \(error)")
    case nil:
        fatalError("Live board lookup timed out")
    case .success(let board)?:
        assert(board.pinCount > 0, "Board should report pins")
        print("   Board “\(board.name)”: about \(board.pinCount) pins")
        var pageResult: Result<(pins: [PinterestBoardPin], nextBookmark: String?), PinterestError>?
        PinterestBoardResolver.shared.fetchPins(of: board, bookmark: nil) { pageResult = $0; sem.signal() }
        _ = sem.wait(timeout: .now() + 20)
        guard case .success(let page)? = pageResult else {
            if case .failure(.rateLimited)? = pageResult { print("   ⚠️ rate-limited on the pin page; skipping"); return }
            fatalError("Live pin page failed: \(String(describing: pageResult))")
        }
        assert(!page.pins.isEmpty, "First page should have pins")
        assert(page.pins.allSatisfy { $0.thumbnailURL.host?.hasSuffix("pinimg.com") == true }, "Thumbnails come from Pinterest's CDN")
        print("   First page: \(page.pins.count) pins, \(page.pins.filter(\.isVideo).count) with an MP4")
    }
    var missing: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver.shared.fetchBoard(username: "thandisibanda1984", slug: "no-such-board-xyz") { missing = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    if case .failure(.rateLimited)? = missing { print("   ⚠️ rate-limited; skipping not-found check") }
    else { assert(missing == .failure(.notFound), "A missing board must report notFound, got \(String(describing: missing))") }
    // A public board on a PRIVATE profile (a real friend's account): must say "private profile", not "secret or deleted".
    var privateResult: Result<PinterestBoard, PinterestError>?
    PinterestBoardResolver().fetchBoard(username: "apurvasavadi03", slug: "prakrutisaar") { privateResult = $0; sem.signal() }
    _ = sem.wait(timeout: .now() + 20)
    if case .failure(.rateLimited)? = privateResult { print("   ⚠️ rate-limited; skipping private-profile check") }
    else { assert(privateResult == .failure(.privateProfile), "Board on a private profile must report privateProfile, got \(String(describing: privateResult))") }
    print("✅ testPinterestLiveBoard passed!")
}

print("\n--- Running Que Core Verification Tests ---")
func testConcealedClipboardIsSkipped() {
    print("Running testConcealedClipboardIsSkipped...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.que.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let watcher = ClipboardWatcher(queueManager: queueManager, pasteboard: pasteboard)
    let pngData = createMockPNGData()

    // Control: a plain image copy is captured.
    pasteboard.clearContents()
    pasteboard.setData(pngData, forType: .png)
    watcher.checkForNewClipboardContent()
    assert(queueManager.count == 1, "Plain image copy should be captured")

    // Same image tagged as concealed (password manager) must be ignored.
    pasteboard.clearContents()
    pasteboard.setData(pngData, forType: .png)
    pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    watcher.checkForNewClipboardContent()
    assert(queueManager.count == 1, "Concealed copy must not enter the deck")
    print("✅ testConcealedClipboardIsSkipped passed!")
}

/// Every SF Symbol named in Que's code must exist on macOS 13 (Que's minimum): a missing symbol draws nothing, which
/// left Shake to Clear's icon empty for a user on an older macOS. Newer symbols need a runtime fallback (`QueSymbol`).
/// Checked against macOS's own symbol list, from the source files (run from the repo root; skips if either is missing).
func testSymbolsExistOnMacOS13() {
    let plistPath = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
    let sourcesDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/QueCore")
    guard let plist = NSDictionary(contentsOfFile: plistPath),
          let symbols = plist["symbols"] as? [String: String],
          let releases = plist["year_to_release"] as? [String: [String: String]],
          let files = try? FileManager.default.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil),
          !files.isEmpty else {
        print("⚠️ testSymbolsExistOnMacOS13 skipped (symbol list or sources not found)")
        return
    }
    let pattern = try! NSRegularExpression(pattern: #"(?:systemName|systemSymbolName|symbol): "([a-z0-9.]+)""#)
    var checked = 0
    for file in files where file.pathExtension == "swift" {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            if text.contains("// SYMBOL-FALLBACK: \(name)") { continue }   // newer symbol with a checked fallback
            guard let year = symbols[name] else {
                assert(false, "\(file.lastPathComponent): SF Symbol “\(name)” doesn't exist")
                continue
            }
            let macOS = releases[year]?["macOS"] ?? "99"
            let major = Double(macOS) ?? 99
            assert(major <= 13, "\(file.lastPathComponent): SF Symbol “\(name)” needs macOS \(macOS); Que supports 13+. Add a fallback.")
            checked += 1
        }
    }
    assert(checked > 20, "Expected to find Que's symbols in the sources (found \(checked))")
    print("✅ testSymbolsExistOnMacOS13 passed! (\(checked) symbol uses)")
}

func testClearCountBumps() {
    let q = DeckQueueManager()
    defer { q.cleanup() }
    let before = q.clearCount
    q.clear()
    assert(q.clearCount == before + 1, "clear() must bump clearCount so in-flight jobs can drop their results")
    q.cleanup()
}

func testVersionCompare() {
    print("Running testVersionCompare...")
    assert(UpdateManager.compare("2.10.0", "2.9.0") > 0, "Numbers, not text: 2.10 is newer than 2.9")
    assert(UpdateManager.compare("2.6.1", "2.6.0") > 0)
    assert(UpdateManager.compare("2.6.0", "2.7.0") < 0)
    assert(UpdateManager.compare("2.6", "2.6.0") == 0, "Missing parts count as 0")
    assert(UpdateManager.compare("2.6.0", "2.6.0") == 0)
    assert(UpdateManager.compare("2.7.0-beta", "2.6.0") > 0, "A suffix doesn't hide the last number")
    print("✅ testVersionCompare passed!")
}

/// The updater only installs Que.zip from this repo's GitHub releases; anything else opens the release page instead.
func testUpdaterTrustsOnlyThisRepo() {
    print("Running testUpdaterTrustsOnlyThisRepo...")
    let base = "https://github.com/spandanmahajan-rgb/que/releases/download/v9.9.9/"
    func release(_ assets: [(String, String)]) -> [String: Any] {
        ["assets": assets.map { ["name": $0.0, "browser_download_url": $0.1] }]
    }
    assert(UpdateManager.zipAssetURL(in: release([("Que.dmg", base + "Que.dmg"), ("Que.zip", base + "Que.zip")]))?
        .lastPathComponent == "Que.zip", "Picks the zip, not the DMG")
    assert(UpdateManager.zipAssetURL(in: release([("Que.zip", "https://github.com/someone/else/releases/download/v1/Que.zip")])) == nil,
           "Another repo's release is refused")
    assert(UpdateManager.zipAssetURL(in: release([("Que.zip", "http://github.com/spandanmahajan-rgb/que/releases/download/v1/Que.zip")])) == nil,
           "Plain http is refused")
    assert(UpdateManager.zipAssetURL(in: release([("Que.zip", "https://evil.example/spandanmahajan-rgb/que/releases/download/v1/Que.zip")])) == nil,
           "Another host is refused")
    assert(UpdateManager.zipAssetURL(in: release([("Que.pkg", base + "Que.pkg")])) == nil, "No installer packages")
    assert(UpdateManager.zipAssetURL(in: [:]) == nil, "No assets, no install")
    assert(UpdateManager.isTrustedFinalHost("objects.githubusercontent.com"))
    assert(UpdateManager.isTrustedFinalHost("github.com"))
    assert(!UpdateManager.isTrustedFinalHost("githubusercontent.com.evil.example"))
    assert(!UpdateManager.isTrustedFinalHost(nil))
    print("✅ testUpdaterTrustsOnlyThisRepo passed!")
}

/// At its limit Que turns new images away (never deletes any) and says so once per attempt.
func testQueStopsAtItsLimit() {
    print("Running testQueStopsAtItsLimit...")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("que-full-\(UUID().uuidString)")
    let qm = DeckQueueManager(sessionBaseDirectory: dir)
    qm.capacity = 3
    var fullNotices = 0
    qm.onFull = { fullNotices += 1 }
    for _ in 0..<3 { assert(qm.add(imageData: createMockPNGData()) != nil) }
    assert(qm.isFull && fullNotices == 0, "Exactly at the limit: full, nothing said yet")
    assert(qm.add(imageData: createMockPNGData()) == nil, "A 4th image is turned away")
    assert(qm.count == 3 && fullNotices == 1, "Nothing deleted, one notice")
    // Files from Finder: only what fits joins, the extra copies are cleaned up.
    qm.remove(id: qm.items[0].id)
    let src = dir.appendingPathComponent("src.png")
    try? createMockPNGData().write(to: src)
    var added: [DeckItem]?
    qm.addFiles([src, src, src]) { added = $0 }
    waitFor(5) { added != nil }
    assert(added?.count == 1 && qm.count == 3 && fullNotices == 2, "One of three fits; the rest is reported")
    let files = (try? FileManager.default.contentsOfDirectory(at: qm.sessionDirectory, includingPropertiesForKeys: nil)) ?? []
    assert(files.count == 3, "Turned-away copies don't linger on disk")
    try? FileManager.default.removeItem(at: dir)
    print("✅ testQueStopsAtItsLimit passed!")
}

/// Only a zip sealed with the release key installs: a changed file, another key or no seal is refused.
func testUpdateSeal() {
    print("Running testUpdateSeal...")
    let testKey = Curve25519.Signing.PrivateKey()
    let priv = testKey.rawRepresentation.base64EncodedString(), pub = testKey.publicKey.rawRepresentation.base64EncodedString()
    let zip = Data("pretend this is Que.zip".utf8)
    let seal = try! UpdateSignature.sign(zip, privateKeyBase64: priv)
    assert(UpdateSignature.isValid(zip, signatureBase64: seal + "\n", publicKeyBase64: pub), "Sealed zip passes (a trailing newline is fine)")
    assert(!UpdateSignature.isValid(zip + Data([0]), signatureBase64: seal, publicKeyBase64: pub), "A changed zip fails")
    assert(!UpdateSignature.isValid(zip, signatureBase64: seal), "Sealed with another key: fails against Que's key")
    assert(!UpdateSignature.isValid(zip, signatureBase64: "", publicKeyBase64: pub), "No seal fails")
    assert(Data(base64Encoded: UpdateSignature.publicKey)?.count == 32, "Que's public key is a real Ed25519 key")
    // The install gate itself (what the updater calls on the downloaded file).
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("que-seal-\(UUID().uuidString).zip")
    try! zip.write(to: file)
    assert(UpdateSignature.isSealed(fileAt: file, signatureBase64: seal, publicKeyBase64: pub), "Sealed file installs")
    assert(!UpdateSignature.isSealed(fileAt: file, signatureBase64: nil, publicKeyBase64: pub), "No seal: refused")
    assert(!UpdateSignature.isSealed(fileAt: file, signatureBase64: seal), "Wrong key: refused")
    try! (zip + Data([1])).write(to: file)
    assert(!UpdateSignature.isSealed(fileAt: file, signatureBase64: seal, publicKeyBase64: pub), "Changed file: refused")
    try? FileManager.default.removeItem(at: file)
    assert(!UpdateSignature.isSealed(fileAt: file, signatureBase64: seal, publicKeyBase64: pub), "Missing file: refused")
    print("✅ testUpdateSeal passed!")
}

func testReleaseNotesAsBullets() {
    print("Running testReleaseNotesAsBullets...")
    let bullets = UpdateManager.releaseNoteItems("- Hold ⌥ to call Que over.\n* **Faster** drops\n\n• Shake icon on older macOS")
    assert(bullets == ["Hold ⌥ to call Que over.", "Faster drops", "Shake icon on older macOS"], "Bullet lines come out clean: \(bullets)")
    let paragraph = UpdateManager.releaseNoteItems("Que now works with one key. ⌘ no longer moves Que, so ⌘-click is safe. Icons show on older macOS.")
    assert(paragraph.count == 3, "An old-style paragraph becomes one item per sentence: \(paragraph)")
    let many = UpdateManager.releaseNoteItems((1...12).map { "- Change \($0)" }.joined(separator: "\n"))
    assert(many.count == 8 && many.last == "And a few smaller fixes.", "Long lists are capped")
    assert(UpdateManager.releaseNoteItems("## What's new\n- One").first == "One", "Headings are dropped")
    let view = UpdateManager.releaseNotesView(bullets)
    assert(view.frame.width == 300 && view.frame.height > 40, "The notes view has a real size")
    print("✅ testReleaseNotesAsBullets passed!")
}

/// "Report a Problem…": the form link carries only Que/Mac details and the sanitized text of Que's recent messages.
/// Never the clipboard, links or board names; "What happened?" is left for the user.
func testProblemReport() {
    print("Running testProblemReport...")
    ProblemReport.resetForTesting()
    let now = Date()
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString("CLIPBOARD-SECRET https://example.com/private", forType: .string)

    for i in 1...12 { ProblemReport.record(PillNotice("Message \(i)"), at: now.addingTimeInterval(-600)) }
    ProblemReport.record(PillNotice("12 pins from “My secret board” joined Que", detail: "See https://pinterest.com/x/y"),
                         at: now.addingTimeInterval(-90))
    let recent = ProblemReport.recentText(now: now)
    let lines = recent.split(separator: "\n").filter { !$0.isEmpty && !$0.hasPrefix("Update log") }
    assert(lines.prefix(10).count == 10 && !recent.contains("Message 3\n") && recent.contains("Message 12"),
           "Keeps only the last 10 messages: \(recent)")
    assert(recent.contains("1 min ago  12 pins from “…” joined Que / See [link]"), "Board names and links removed: \(recent)")
    assert(recent.contains("10 min ago  Message 4"), "Relative times")

    let url = ProblemReport.url(now: now)!.absoluteString
    assert(url.hasPrefix(ProblemReport.formURL + "?usp=pp_url&"), "Opens the published form, pre-filled")
    assert(url.contains(ProblemReport.detailsField + "=Que%20") && url.contains(ProblemReport.recentField + "="),
           "Both Que-filled answers are in the link")
    assert(!url.contains("entry.54490118"), "\"What happened?\" is left for the user")
    let decoded = url.removingPercentEncoding ?? ""
    assert(!decoded.contains("CLIPBOARD-SECRET") && !decoded.contains("example.com") && !decoded.contains("pinterest.com")
           && !decoded.contains("My secret board"), "No clipboard, links or board names in the link")
    assert(!url.contains("+"), "Spaces are encoded as %20 (Google reads + as a space)")
    assert(url.count < 2500, "The link stays a safe length (\(url.count))")

    let details = ProblemReport.details()
    assert(details.hasPrefix("Que \(UpdateManager.currentVersion), macOS ") &&
           (details.hasSuffix("Apple silicon") || details.hasSuffix("Intel")), "Details: \(details)")

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    assert(ProblemReport.failedUpdateLines(log: "a check\nanother check") == nil, "A healthy update log is left out")
    let failed = ProblemReport.failedUpdateLines(log: "check\ndownload FAILED: \(home)/Downloads/x.zip")
    assert(failed?.last == "download FAILED: ~/Downloads/x.zip", "Failed update lines are included, home folder shortened")
    ProblemReport.resetForTesting()
    assert(ProblemReport.recentText(now: now).hasPrefix("No messages yet"), "Empty list says so")
    pasteboard.clearContents()
    print("✅ testProblemReport passed!")
}

// MARK: - GIF editor

/// A 10 s, 10 fps H.264 video whose red channel steps up every second (second n ≈ red n × 25), so a GIF's first frame
/// tells which part of the video it came from.
func makeSteppedTestVideo(seconds: Int = 10) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("que-test-\(UUID().uuidString).mp4")
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 128])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 128])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<(seconds * 10) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let bytes = CVPixelBufferGetBytesPerRow(buffer!) * 128
        for i in stride(from: 0, to: bytes, by: 4) { base[i] = 0; base[i + 1] = 0; base[i + 2] = UInt8(frame / 10 * 25); base[i + 3] = 255 }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    assert(writer.status == .completed, "Test video written: \(String(describing: writer.error))")
    return url
}

func redOfFirstFrame(_ gif: URL) -> Int {
    let source = CGImageSourceCreateWithURL(gif as CFURL, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var pixel = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return Int(pixel[0])
}

func waitFor(_ seconds: Double = 20, until done: () -> Bool) {
    let deadline = Date().addingTimeInterval(seconds)
    while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
}

/// A video copied in Finder: its GIF joins Que able to be edited, pointing at the user's own file (never moved or deleted).
func testCopiedVideoKeepsItsSource() {
    print("Running testCopiedVideoKeepsItsSource...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.que.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let watcher = ClipboardWatcher(queueManager: queueManager, pasteboard: pasteboard)
    let usersVideo = makeSteppedTestVideo(seconds: 3)
    defer { try? FileManager.default.removeItem(at: usersVideo) }

    pasteboard.clearContents()
    pasteboard.writeObjects([usersVideo as NSURL])
    watcher.checkForNewClipboardContent()
    waitFor { queueManager.count == 1 }
    let gif = queueManager.items.first!
    assert(gif.fileURL.pathExtension == "gif" && gif.sourceVideoURL == usersVideo, "The GIF remembers the user's video")
    assert(GIFSegmentEditing.canEdit(gif), "So it gets the edit button")
    queueManager.remove(id: gif.id)
    assert(FileManager.default.fileExists(atPath: usersVideo.path), "Removing the GIF leaves the user's video alone")
    assert(PillNotice.gifEditFailed().tone == .error, "A failed edit after the preview closed is an error notice")
    print("✅ testCopiedVideoKeepsItsSource passed!")
}

/// Stream-only pins: Que downloads the stream's one-file rendition like an MP4 (fast, and kept for the GIF editor);
/// streams split into pieces, or encrypted, still go the real-time way.
func testStreamOnlyPinsBecomeFiles() {
    print("Running testStreamOnlyPinsBecomeFiles...")
    let base = URL(string: "https://v1.pinimg.com/videos/iht/hls/2c/ee/32/abc.m3u8")!
    let master = """
    #EXTM3U
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio1",NAME="1",URI="abc_audio.m3u8",CHANNELS="2"
    #EXT-X-STREAM-INF:BANDWIDTH=296592,RESOLUTION=240x300,FRAME-RATE=30,AUDIO="audio1"
    abc_240w.m3u8
    #EXT-X-STREAM-INF:BANDWIDTH=705800,RESOLUTION=544x680,FRAME-RATE=30,AUDIO="audio1"
    abc_540w.m3u8

    #EXT-X-STREAM-INF:BANDWIDTH=1146728,RESOLUTION=720x900,FRAME-RATE=30,AUDIO="audio1"
    abc_720w.m3u8
    """
    assert(PinterestMediaResolver.bestVariant(inMasterPlaylist: master, base: base, targetWidth: 500)?.absoluteString
           == "https://v1.pinimg.com/videos/iht/hls/2c/ee/32/abc_540w.m3u8", "Smallest rendition that covers the GIF")
    assert(PinterestMediaResolver.bestVariant(inMasterPlaylist: master, base: base, targetWidth: 1000)?.lastPathComponent
           == "abc_720w.m3u8", "None wide enough: the widest")
    assert(PinterestMediaResolver.bestVariant(inMasterPlaylist: "#EXTM3U\n", base: base, targetWidth: 500) == nil)

    let oneFile = """
    #EXTM3U
    #EXT-X-PLAYLIST-TYPE:VOD
    #EXT-X-MAP:URI="abc_540w.cmfv",BYTERANGE="978@0"
    #EXTINF:2
    #EXT-X-BYTERANGE:153621@1102
    abc_540w.cmfv
    #EXTINF:2
    #EXT-X-BYTERANGE:128662@154723
    abc_540w.cmfv
    #EXT-X-ENDLIST
    """
    let variant = URL(string: "https://v1.pinimg.com/videos/iht/hls/2c/ee/32/abc_540w.m3u8")!
    assert(PinterestMediaResolver.singleMediaFile(inMediaPlaylist: oneFile, base: variant)?.absoluteString
           == "https://v1.pinimg.com/videos/iht/hls/2c/ee/32/abc_540w.cmfv", "One file: download it")
    let huge = oneFile.replacingOccurrences(of: "153621@1102", with: "60000000@1102")
    assert(PinterestMediaResolver.singleMediaFile(inMediaPlaylist: huge, base: variant) == nil,
           "Over 40 MB: record the stream instead of downloading it all")
    let pieces = "#EXTM3U\n#EXTINF:2\nseg1.ts\n#EXTINF:2\nseg2.ts\n"
    assert(PinterestMediaResolver.singleMediaFile(inMediaPlaylist: pieces, base: variant) == nil, "Pieces: real-time, as before")
    let encrypted = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"k\"\n#EXTINF:2\nv.cmfv\n"
    assert(PinterestMediaResolver.singleMediaFile(inMediaPlaylist: encrypted, base: variant) == nil, "Encrypted: never")

    guard runLiveTests else { print("✅ testStreamOnlyPinsBecomeFiles passed (live part skipped)"); return }
    // Live: a stream-only pin (no MP4 at all) now resolves to its one file.
    var result: PinterestMediaResult?, answered = false
    PinterestMediaResolver.shared.resolveMedia(from: "https://in.pinterest.com/pin/1133499799977101611/") {
        result = $0; answered = true
    }
    waitFor(15) { answered }
    // Pinterest can change or remove this pin: anything but a single-file video skips the live checks (it's their
    // side that changed, so it must not block a release).
    guard case .video(let url)? = result, !url.absoluteString.contains(".m3u8") else {
        print("   ⚠️ The live stream-only pin isn't a single-file video right now; skipping the live checks")
        print("✅ testStreamOnlyPinsBecomeFiles passed!")
        return
    }
    print("   Stream-only pin resolved to:", url.lastPathComponent)

    // Live, the whole way: copying that pin's link gives a GIF with the pencil (its video is kept in Que's folder).
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.que.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let watcher = ClipboardWatcher(queueManager: queueManager, pasteboard: pasteboard)
    pasteboard.clearContents()
    pasteboard.setString("https://in.pinterest.com/pin/1133499799977101611/", forType: .string)
    watcher.checkForNewClipboardContent()
    waitFor(40) { queueManager.count == 1 }
    if let gif = queueManager.items.first {
        assert(GIFSegmentEditing.canEdit(gif) && queueManager.owns(gif.sourceVideoURL!), "Stream-only pin's GIF can be edited")
    } else {
        print("   ⚠️ The pin didn't arrive (network); skipping the copy check")
    }
    print("✅ testStreamOnlyPinsBecomeFiles passed!")
}

/// Start/end handles: independent, clamped to the video, never shorter than 0.5 s or longer than 8 s.
func testGIFSegmentSelection() {
    print("Running testGIFSegmentSelection...")
    var s = GIFSegment(sourceDuration: 60)
    assert(s.start == 0 && s.end == 4 && s.isValid, "Opens on what the instant GIF shows: the first 4 s")
    s.moveEnd(to: 30)
    assert(s.end == 8, "The end stops at 8 s long")
    s.moveStart(to: 7.9)
    assert(abs(s.start - 7.5) < 0.0001 && s.end == 8, "The start stops 0.5 s before the end; the end stays put")
    s.moveEnd(to: 70)
    assert(s.end == 15.5, "Still 8 s at most, from wherever the start is")
    s.moveStart(to: -3)
    assert(s.start == 7.5, "The start can't pull the part past 8 s either")

    let late = GIFSegment(sourceDuration: 60, start: 50, length: 4)
    assert(late.start == 50 && late.end == 54 && late.isValid, "A later part of a long video")
    let tail = GIFSegment(sourceDuration: 60, start: 59.9, length: 4)
    assert(tail.start == 59.5 && tail.end == 60 && tail.isValid, "Past the end: clamped to the last 0.5 s")
    let short = GIFSegment(sourceDuration: 2)
    assert(short.start == 0 && short.end == 2 && short.isValid, "A 2 s video: the whole video")
    let tiny = GIFSegment(sourceDuration: 0.3)
    assert(tiny.length == 0.3 && tiny.isValid, "Shorter than the minimum: the whole video is still allowed")
    assert(!GIFSegment(sourceDuration: 0).isValid, "A video with no length can't be used")

    assert(GIFSegment.timeLabel(2.44) == "0:02.4" && GIFSegment.timeLabel(65) == "1:05.0"
           && GIFSegment.timeLabel(59.96) == "1:00.0", "Time labels")
    assert(GIFSegment.lengthLabel(4) == "4.0 s")

    // Moving the whole part keeps its length exactly and stays inside the video (long and short videos).
    var moving = GIFSegment(sourceDuration: 60, start: 10, length: 3.7)
    moving.slide(toStart: 30)
    assert(moving.start == 30 && abs(moving.length - 3.7) < 1e-9, "Moved later, same length")
    moving.slide(toStart: 2)
    assert(moving.start == 2 && abs(moving.length - 3.7) < 1e-9, "Moved earlier, same length")
    moving.slide(toStart: 58)
    assert(moving.end == 60 && abs(moving.length - 3.7) < 1e-9 && moving.isValid, "Stops at the end of the video")
    moving.slide(toStart: -5)
    assert(moving.start == 0 && abs(moving.length - 3.7) < 1e-9, "Stops at the start of the video")
    var whole = GIFSegment(sourceDuration: 2)
    whole.slide(toStart: 1)
    assert(whole.start == 0 && whole.end == 2, "A part as long as the video can't move")
    var edges = GIFSegment(sourceDuration: 60, start: 10, length: 4)
    edges.moveStart(to: 12)
    assert(edges.start == 12 && edges.end == 14, "Left handle: the end stays put")
    edges.moveEnd(to: 16)
    assert(edges.start == 12 && edges.end == 16, "Right handle: the start stays put")
    assert(edges.contains(12) && edges.contains(15.9) && !edges.contains(16) && !edges.contains(11.9))

    // What a press grabs. Part at x 100–200, handles 10 pt outside it, the playhead dot at (150, 22).
    func hit(_ x: CGFloat, _ y: CGFloat = 22, start: CGFloat = 100, end: CGFloat = 200,
             dot: CGPoint? = CGPoint(x: 150, y: 22)) -> GIFTimelineTarget {
        GIFTimelineTarget.at(CGPoint(x: x, y: y), startX: start, endX: end, playhead: dot)
    }
    assert(hit(95) == .startHandle && hit(87) == .startHandle && hit(103) == .startHandle, "Left handle, with slop")
    assert(hit(205) == .endHandle && hit(213) == .endHandle && hit(197) == .endHandle, "Right handle, with slop")
    assert(hit(150) == .playhead && hit(155) == .playhead && hit(150, 28) == .playhead, "On the dot")
    assert(hit(150, 40) == .range && hit(150, 4) == .range, "Above or below the dot is the part's body, not the playhead")
    assert(hit(120) == .range && hit(180) == .range, "The part's body moves the part")
    assert(hit(120, dot: nil) == .range, "No playhead: still the body")
    assert(hit(50) == .seek && hit(260) == .seek, "Outside the part: seek")
    assert(hit(101, dot: CGPoint(x: 101, y: 22)) == .startHandle, "A handle wins over the dot sitting on it")
    assert(hit(97, dot: CGPoint(x: 100, y: 22)) == .startHandle, "Even when the dot sits right on the edge")
    // A very short part (3 pt wide): both handles overlap the body; the nearer handle wins, never the wrong one.
    assert(hit(98, start: 100, end: 103) == .startHandle && hit(106, start: 100, end: 103) == .endHandle)

    let times = VideoToGIFConverter.frameTimes(start: 6, length: 2, sourceDuration: 10, fps: 14)
    assert(times.count == 28 && times.first == 6 && abs(times.last! - (6 + 27.0 / 14)) < 0.0001, "6–8 s at 14 fps")
    assert(VideoToGIFConverter.frameTimes(start: 0, length: 4, sourceDuration: 10, fps: 14).count == 56,
           "Start 0 = the instant GIF's 56 frames, unchanged")
    assert(VideoToGIFConverter.frameTimes(start: 9, length: 4, sourceDuration: 10, fps: 14).count == 14, "Clamped at the end")
    assert(VideoToGIFConverter.frameTimes(start: 11, length: 4, sourceDuration: 10, fps: 14).isEmpty, "Past the end: nothing")
    print("✅ testGIFSegmentSelection passed!")
}

/// Shake to clear needs a deliberate shake: a quick flick or jitter doesn't clear Que.
func testShakeNeedsIntent() {
    print("Running testShakeNeedsIntent...")
    /// Replays a side-to-side path at 60 fps: `swings` swings of `width` pt, each taking `swingTime` s. True if it cleared.
    func shake(swings: Int, width: CGFloat, swingTime: Double, start: Double = 1000) -> Bool {
        let detector = ShakeDetector()
        var fired = false
        detector.onShakeDetected = { fired = true }
        let steps = max(1, Int(swingTime * 60))
        var t = start, x: CGFloat = 500
        for s in 0..<swings {
            let dir: CGFloat = s % 2 == 0 ? 1 : -1
            for _ in 0..<steps { x += dir * width / CGFloat(steps); t += 1.0 / 60; detector.observe(x: x, at: t) }
        }
        return fired
    }
    assert(shake(swings: 6, width: 120, swingTime: 0.07), "A deliberate fast shake clears")
    assert(shake(swings: 7, width: 90, swingTime: 0.07), "Three-plus quick back-and-forths clear")
    assert(!shake(swings: 3, width: 250, swingTime: 0.06), "A fast flick and back doesn't clear")
    assert(!shake(swings: 5, width: 120, swingTime: 0.07), "Two back-and-forths aren't enough any more")
    assert(!shake(swings: 6, width: 80, swingTime: 0.15), "A slower wiggle doesn't clear")
    assert(!shake(swings: 30, width: 20, swingTime: 0.034), "Small fast jitter doesn't clear")
    print("✅ testShakeNeedsIntent passed!")
}

/// Make GIF from selected images: one frame per image, each held the chosen seconds, all on the first image's canvas.
func testSlideshowGIF() {
    print("Running testSlideshowGIF...")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("que-slideshow-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
    try! createMockPNGData().write(to: a)
    let wide = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4,
                                hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try! wide.representation(using: .png, properties: [:])!.write(to: b)

    let data = VideoToGIFConverter.shared.slideshowGIF(imageURLs: [a, b, a], secondsEach: 2)
    let source = data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
    assert(source.map { CGImageSourceGetCount($0) } == 3, "One frame per image")
    let props = CGImageSourceCopyPropertiesAtIndex(source!, 1, nil) as? [CFString: Any]
    let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    assert((gif?[kCGImagePropertyGIFDelayTime] as? Double) == 2, "Held 2 s")
    let frame = CGImageSourceCreateImageAtIndex(source!, 1, nil)!
    assert(frame.width == 40 && frame.height == 40, "First image's shape, sized for the largest image")
    assert(VideoToGIFConverter.shared.slideshowGIF(imageURLs: [a, dir.appendingPathComponent("gone.png")], secondsEach: 1) == nil,
           "A missing image fails instead of silently dropping it")
    print("✅ testSlideshowGIF passed!")
}

/// The filmstrip with real mouse events: each interaction moves only its own thing. Handles and the part never move
/// the playhead; only a press on the dot drags it (and makes it a pill); a click elsewhere seeks without dragging.
func testTimelineInteractions() {
    print("Running testTimelineInteractions...")
    // As in the editor: 392 pt wide, so the 10 s video spans x 10–382 (37.2 pt a second); the strip's middle is y 22.
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 392, height: 44), styleMask: .borderless,
                          backing: .buffered, defer: false)
    let timeline = SegmentTimelineView(frame: NSRect(x: 0, y: 0, width: 392, height: 44))
    window.contentView = timeline
    func x(_ t: Double) -> CGFloat { 10 + CGFloat(t) * 37.2 }
    func event(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat = 22) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    var changes: [(SegmentTimelineView.Edge, Double)] = [], ended: [SegmentTimelineView.Edge] = []
    timeline.onChange = { changes.append(($0, $1)) }
    timeline.onDragEnded = { ended.append($0) }
    func reset(start: Double = 2, length: Double = 4, playhead: Double = 3) {
        timeline.segment = GIFSegment(sourceDuration: 10, start: start, length: length)
        timeline.playhead = playhead
        changes = []; ended = []
    }
    func press(_ x0: CGFloat, drag dx: CGFloat? = nil, y: CGFloat = 22) {
        timeline.mouseDown(with: event(.leftMouseDown, x0, y))
        if let dx = dx { timeline.mouseDragged(with: event(.leftMouseDragged, x0 + dx / 2, y))
                         timeline.mouseDragged(with: event(.leftMouseDragged, x0 + dx, y)) }
        timeline.mouseUp(with: event(.leftMouseUp, x0 + (dx ?? 0), y))
    }
    let near = { (a: Double, b: Double) in abs(a - b) < 0.05 }

    // Left handle (its grip sits 5 pt left of the part): only the start changes; the playhead stays put.
    reset()
    press(x(2) - 5, drag: 37.2)
    assert(near(timeline.segment!.start, 3) && timeline.segment!.end == 6 && timeline.playhead == 3,
           "Left handle: start moves, end and playhead don't (\(timeline.segment!), playhead \(timeline.playhead))")
    assert(ended == [.start] && !changes.contains { $0.0 == .playhead }, "Reported as a start edit only")
    // A plain click on the left edge (the old bug): nothing moves.
    reset()
    press(x(2) - 2)
    assert(timeline.segment == GIFSegment(sourceDuration: 10, start: 2, length: 4) && timeline.playhead == 3,
           "Clicking an edge never moves the playhead")
    // Right handle: only the end changes.
    reset()
    press(x(6) + 5, drag: 37.2)
    assert(timeline.segment!.start == 2 && near(timeline.segment!.end, 7) && timeline.playhead == 3, "Right handle")

    // Body (above the dot's line, away from it): the whole part moves, same length; the playhead stays.
    reset()
    press(x(4), drag: 74.4, y: 38)
    assert(near(timeline.segment!.start, 4) && abs(timeline.segment!.length - 4) < 1e-9 && timeline.playhead == 3,
           "Body drag moves the part, keeps its length, leaves the playhead")
    reset()
    press(x(4), drag: 1000, y: 38)
    assert(timeline.segment!.end == 10 && abs(timeline.segment!.length - 4) < 1e-9, "Clamped at the video's end")
    // A plain click on the body looks at that moment.
    reset()
    press(x(5), y: 38)
    assert(near(timeline.playhead, 5) && timeline.segment!.start == 2 && ended == [.playhead], "Body click seeks")

    // The dot: press makes it a pill without moving it; dragging moves only the playhead; release makes it a dot.
    reset(playhead: 4)
    timeline.mouseDown(with: event(.leftMouseDown, x(4) + 3))
    assert(timeline.isPill && timeline.playhead == 4, "Pressing the dot: a pill, no jump (grab point kept)")
    timeline.mouseDragged(with: event(.leftMouseDragged, x(5) + 3))
    assert(near(timeline.playhead, 5) && timeline.segment!.start == 2 && timeline.segment!.end == 6, "Dragging the pill")
    timeline.mouseUp(with: event(.leftMouseUp, x(5) + 3))
    assert(!timeline.isPill && near(timeline.playhead, 5) && ended == [.playhead], "Released: a dot again, same time")

    // Outside the part: a click seeks, and dragging from there doesn't drag the playhead.
    reset()
    press(x(8.5), drag: 74.4)
    assert(near(timeline.playhead, 8.5) && !timeline.isPill && timeline.segment!.start == 2,
           "A timeline click seeks once; the following drag does nothing")
    print("✅ testTimelineInteractions passed!")
}

/// Replacing keeps the item's identity, place and source; a missing item changes nothing.
func testReplaceGIFInPlace() {
    print("Running testReplaceGIFInPlace...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let png = createMockPNGData()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent("que-test-\(UUID().uuidString).mp4")
    try! Data([1, 2, 3]).write(to: source)
    let adopted = queueManager.adoptSourceVideo(source)!
    _ = queueManager.add(imageData: png, extension: "png")
    let gif = queueManager.add(imageData: png, extension: "gif", originalName: nil, sourceVideo: adopted)!
    _ = queueManager.add(imageData: png, extension: "png")
    let before = queueManager.items.map { $0.id }

    let updated = queueManager.replaceImage(of: gif.id, with: png + Data([0]), extension: "gif")!
    assert(queueManager.items.map { $0.id } == before, "Same items, same order, no duplicate")
    assert(updated.id == gif.id && updated.createdAt == gif.createdAt && updated.sourceVideoURL == adopted,
           "Identity and source video kept")
    assert(queueManager.items[1].fileURL == updated.fileURL && updated.fileURL != gif.fileURL
           && FileManager.default.fileExists(atPath: updated.fileURL.path), "The new GIF is in place")
    assert(FileManager.default.fileExists(atPath: gif.fileURL.path), "The old file lingers for apps still reading a drop")
    assert(queueManager.replaceImage(of: UUID(), with: png, extension: "gif") == nil, "Unknown item: nothing happens")
    assert(queueManager.replaceImage(of: gif.id, with: Data(), extension: "gif") == nil
           && queueManager.items[1].fileURL == updated.fileURL, "Empty data: the current GIF stays")
    print("✅ testReplaceGIFInPlace passed!")
}

/// The source video lives in Que's session folder, goes away with its item, and a user's own file is never deleted.
func testGIFSourceVideoCleanup() {
    print("Running testGIFSourceVideoCleanup...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let png = createMockPNGData()
    let download = FileManager.default.temporaryDirectory.appendingPathComponent("que-test-\(UUID().uuidString).mp4")
    try! Data([1]).write(to: download)
    let adopted = queueManager.adoptSourceVideo(download)!
    assert(!FileManager.default.fileExists(atPath: download.path) && queueManager.owns(adopted)
           && adopted.deletingLastPathComponent() == queueManager.sessionDirectory, "Moved into this session's folder")
    let gif = queueManager.add(imageData: png, extension: "gif", sourceVideo: adopted)!
    assert(GIFSegmentEditing.canEdit(gif), "A GIF with its video gets the edit button")
    assert(!GIFSegmentEditing.canEdit(queueManager.add(imageData: png, extension: "png")!), "Images don't")
    queueManager.remove(id: gif.id)
    assert(!FileManager.default.fileExists(atPath: adopted.path), "Removing the GIF removes its downloaded video")

    let usersFile = FileManager.default.temporaryDirectory.appendingPathComponent("que-test-users-\(UUID().uuidString).mov")
    try! Data([1]).write(to: usersFile)
    defer { try? FileManager.default.removeItem(at: usersFile) }
    let fromFinder = queueManager.add(imageData: png, extension: "gif", sourceVideo: usersFile)!
    queueManager.remove(ids: [fromFinder.id])
    assert(FileManager.default.fileExists(atPath: usersFile.path), "A video copied from Finder is never deleted")
    let gone = queueManager.add(imageData: png, extension: "gif",
                                sourceVideo: queueManager.sessionDirectory.appendingPathComponent("missing.mp4"))!
    assert(!GIFSegmentEditing.canEdit(gone), "No edit button once the video is gone")
    print("✅ testGIFSourceVideoCleanup passed!")
}

/// End to end on a real video: a later part replaces the GIF in place; failures and removals leave everything as it was.
func testGIFSegmentEditingEndToEnd() {
    print("Running testGIFSegmentEditingEndToEnd...")
    let queueManager = DeckQueueManager()
    defer { queueManager.cleanup() }
    let video = queueManager.adoptSourceVideo(makeSteppedTestVideo())!

    var instant: Data?
    VideoToGIFConverter.shared.convert(videoURL: video) { data, _ in instant = data }
    waitFor { instant != nil }
    let first = queueManager.add(imageData: createMockPNGData(), extension: "png")!
    let gif = queueManager.add(imageData: instant!, extension: "gif", sourceVideo: video)!
    assert(redOfFirstFrame(gif.fileURL) < 15, "The instant GIF starts at 0 s (unchanged)")

    // Editing 6–8 s of the 10 s video.
    var result: DeckItem?, finished = false
    GIFSegmentEditing.replaceGIF(of: gif.id, in: queueManager, segment: GIFSegment(sourceDuration: 10, start: 6, length: 2)) {
        result = $0; finished = true
    }
    waitFor { finished }
    let updated = result!
    assert(queueManager.items.map { $0.id } == [first.id, gif.id], "Replaced in place: no duplicate, same order")
    let frames = CGImageSourceGetCount(CGImageSourceCreateWithURL(updated.fileURL as CFURL, nil)!)
    assert(frames == 28, "2 s at 14 fps = 28 frames (got \(frames))")
    let red = redOfFirstFrame(updated.fileURL)
    assert(abs(red - 150) < 15, "The new GIF starts at 6 s (red \(red), expected ~150)")
    assert(FileManager.default.fileExists(atPath: video.path), "The video stays for further edits")

    // Conversion failure: the video vanished. The GIF in Que is untouched.
    let moved = video.deletingLastPathComponent().appendingPathComponent("moved.mp4")
    try! FileManager.default.moveItem(at: video, to: moved)
    finished = false; result = nil
    GIFSegmentEditing.replaceGIF(of: gif.id, in: queueManager, segment: GIFSegment(sourceDuration: 10)) {
        result = $0; finished = true
    }
    waitFor { finished }
    assert(result == nil && queueManager.items[1].fileURL == updated.fileURL
           && FileManager.default.fileExists(atPath: updated.fileURL.path), "A failed conversion keeps the current GIF")
    try! FileManager.default.moveItem(at: moved, to: video)

    // An invalid part never starts a conversion.
    finished = false
    GIFSegmentEditing.replaceGIF(of: gif.id, in: queueManager, segment: GIFSegment(sourceDuration: 0)) { result = $0; finished = true }
    assert(finished && result == nil, "Invalid selection: refused at once")

    // The GIF is removed while its new version is being made (preview closed, Que cleared): nothing comes back.
    finished = false
    GIFSegmentEditing.replaceGIF(of: gif.id, in: queueManager, segment: GIFSegment(sourceDuration: 10, start: 2)) {
        result = $0; finished = true
    }
    queueManager.clear()   // the old session's files (the video too) linger 60 s, so the conversion itself succeeds
    waitFor { finished }
    assert(result == nil && queueManager.isEmpty, "No GIF reappears after Que was cleared")
    print("✅ testGIFSegmentEditingEndToEnd passed!")
}

testGIFSegmentSelection()
testCopiedVideoKeepsItsSource()
testStreamOnlyPinsBecomeFiles()
testTimelineInteractions()
testSlideshowGIF()
testShakeNeedsIntent()
testReplaceGIFInPlace()
testGIFSourceVideoCleanup()
testGIFSegmentEditingEndToEnd()
testQueueAddAndClear()
testSymbolsExistOnMacOS13()
testClearCountBumps()
testVersionCompare()
testUpdaterTrustsOnlyThisRepo()
testQueStopsAtItsLimit()
testUpdateSeal()
testReleaseNotesAsBullets()
testProblemReport()
testConcealedClipboardIsSkipped()
testPasteboardWriterPayload()
testDragPasteboard()
testHUDPanelLifecycle()
testPinterestMediaResolverURLDetection()
if runLiveTests { testPinterestLiveVideoResolution() }
testPinterestBoardURLDetection()
testPillNoticeWording()
testBoardPickerSelection()
testPillNoticeShowsAndHides()
testScreenshotOverlayDetection()
testBackgroundImport()
testRemoveSeveralItems()
testLegacyAppRename()
testLoginItemMigration()
testUpdateDotAssets()
testWelcomeOnFreshInstalls()
testWorkingIndicator()
testControlDoubleTap()
testCallStyleWording()
testPinterestWaitIsRemembered()
testSnapEndsWhenQueEmpties()
testHoldAddsWholeBoard()
testBoardPageParsing()
if runLiveTests { testPinterestLiveBoard() }
print("All verification tests passed successfully! 🚀\n")
