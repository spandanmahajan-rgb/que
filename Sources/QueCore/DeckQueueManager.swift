// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public final class DeckQueueManager {
    public private(set) var items: [DeckItem] = []
    public private(set) var sessionDirectory: URL
    /// Bumped by every `clear()`, so background jobs can tell the Que they started for was emptied meanwhile.
    public private(set) var clearCount = 0

    // AUDIT: base directory is now stored (clear() used to hard-code it and ignore a custom base)
    private let baseDirectory: URL

    public var count: Int {
        return items.count
    }

    public var isEmpty: Bool {
        return items.isEmpty
    }

    /// Most images Que holds (a big moodboard is well under it). At the limit new images are turned away, never
    /// deleted, and `onFull` tells the user to clear Que. Each image is a file in the temp folder: this keeps a
    /// login item that runs for weeks from quietly filling the disk.
    public var capacity = 200
    public var isFull: Bool { items.count >= capacity }
    /// Main queue. Shows "Que is full" (set in main.swift).
    public var onFull: (() -> Void)?

    private var observers: [UUID: ([DeckItem]) -> Void] = [:]

    @discardableResult
    public func addObserver(_ observer: @escaping ([DeckItem]) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    private func notifyObservers() {
        let currentItems = items
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (_, observer) in self.observers {
                observer(currentItems)
            }
        }
    }

    public init(sessionBaseDirectory: URL? = nil) {
        // AUDIT: was the shared, world-writable /private/tmp/cursor-deck (0777), so any other account on the
        // Mac could read (or delete) clipboard images. The per-user temp dir (/var/folders/…/T) is 0700.
        let base = sessionBaseDirectory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("que", isDirectory: true)
        self.baseDirectory = base
        let sessionId = UUID().uuidString
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // AUDIT: main.swift keeps `queueManager` as a global, so deinit never runs at quit and every
        // launch/crash/force-quit/update left its session_* folder behind forever. Purge old ones at startup.
        // (Deliberately NOT deleted at quit: "⌘+Click arms the clipboard, then ⌘V in WhatsApp later" must
        // keep working even if the app is quit or auto-updates in between.)
        purgeStaleSessions()
        // Same 24h rule for the old shared folder, so leftovers from older versions stop lingering there.
        if sessionBaseDirectory == nil {
            purgeStaleSessions(in: Self.legacySharedBaseDirectory)
            purgeStaleSessions(in: Self.legacyCursorDeckDirectory)   // the folder CursorDeck 1.x used
        }
    }

    private static let legacySharedBaseDirectory = URL(fileURLWithPath: "/private/tmp/cursor-deck", isDirectory: true)
    private static let legacyCursorDeckDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cursor-deck", isDirectory: true)

    deinit {
        cleanup()
    }

    /// Removes session folders from previous runs that haven't been touched for 24 hours, so anything you
    /// dropped or armed on the clipboard recently (and any other running Que instance, e.g. a dev
    /// build next to the installed app) is never pulled out from under the receiving app.
    private func purgeStaleSessions(in directory: URL? = nil, olderThan age: TimeInterval = 86_400) {
        let base = directory ?? baseDirectory
        let currentName = sessionDirectory.lastPathComponent
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.contentModificationDateKey], options: []
            ) else { return }
            let cutoff = Date().addingTimeInterval(-age)
            for url in entries where url.lastPathComponent.hasPrefix("session_") && url.lastPathComponent != currentName {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff {
                    try? fm.removeItem(at: url)
                }
            }
        }
    }

    /// Returns true if the file was created or owned by Que, preventing self-capture loops
    public func owns(_ url: URL) -> Bool {
        // AUDIT: was `|| url.path.contains("cursor-deck")`, which silently ignored ANY file whose path merely
        // contained that text (e.g. images inside a project folder called cursor-deck). Match the real folder.
        let base = baseDirectory.resolvingSymlinksInPath().path
        let candidate = url.resolvingSymlinksInPath().path
        return candidate == base || candidate.hasPrefix(base + "/")
    }

    @discardableResult
    public func add(imageData: Data, extension fileExt: String = "png", originalName: String? = nil, sourceVideo: URL? = nil) -> DeckItem? {
        guard !imageData.isEmpty else { return nil }
        guard !isFull else { onFull?(); return nil }
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let itemId = UUID()
        let filename = originalName ?? "item_\(items.count + 1)_\(itemId.uuidString.prefix(6)).\(fileExt)"
        let targetURL = sessionDirectory.appendingPathComponent(filename)

        do {
            try imageData.write(to: targetURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetURL.path)
            let item = DeckItem(
                id: itemId,
                type: .image,
                fileURL: targetURL,
                originalFileName: originalName,
                dataSize: imageData.count,
                sourceVideoURL: sourceVideo
            )
            items.append(item)
            DeckThumbnailCache.shared.prewarm(item.fileURL)
            notifyObservers()
            return item
        } catch {
            return nil
        }
    }

    // MARK: - Background import

    /// Serial, so items keep the order they were copied in.
    private let importQueue = DispatchQueue(label: "com.que.import", qos: .userInitiated)
    private static let convertToPNG: Set<String> = ["heic", "heif", "tiff", "tif", "bmp"]

    /// Adds files without blocking the main thread, where the pill animates (a big HEIC/TIFF used to freeze it for up
    /// to a second). HEIC/TIFF/BMP → PNG conversion (rotation applied) and copying run in the background; items are
    /// added on the main queue in the given order. `completion` (main queue) gets the items that were added.
    public func addFiles(_ urls: [URL], completion: (([DeckItem]) -> Void)? = nil) {
        guard !urls.isEmpty else { completion?([]); return }
        let dir = sessionDirectory, firstIndex = items.count + 1
        importQueue.async { [weak self] in
            let prepared = urls.enumerated().compactMap { i, url in Self.importFile(url, into: dir, index: firstIndex + i) }
            DispatchQueue.main.async { self?.commit(prepared, preparedIn: dir, completion: completion) }
        }
    }

    /// Same for image data that must become PNG first (e.g. TIFF from the clipboard).
    public func addConvertingToPNG(_ data: Data, completion: ((DeckItem?) -> Void)? = nil) {
        let dir = sessionDirectory, index = items.count + 1
        importQueue.async { [weak self] in
            var prepared: [PreparedFile] = []
            if let png = CGImageSourceCreateWithData(data as CFData, nil).flatMap(Self.pngData(from:)),
               let file = Self.write(png, ext: "png", into: dir, index: index, originalName: nil) {
                prepared.append(file)
            }
            DispatchQueue.main.async {
                self?.commit(prepared, preparedIn: dir) { completion?($0.first) }
            }
        }
    }

    private struct PreparedFile { let url: URL; let size: Int; let originalName: String?; var originalURL: URL? = nil }

    private func commit(_ prepared: [PreparedFile], preparedIn dir: URL, completion: (([DeckItem]) -> Void)?) {
        // The deck was cleared while these were being prepared: they belong to the old session, drop them.
        guard sessionDirectory == dir else {
            prepared.forEach { try? FileManager.default.removeItem(at: $0.url) }
            completion?([])
            return
        }
        let room = max(0, capacity - items.count)
        prepared.dropFirst(room).forEach { try? FileManager.default.removeItem(at: $0.url) }
        if prepared.count > room { onFull?() }
        let added = prepared.prefix(room).map { DeckItem(type: .image, fileURL: $0.url, originalFileName: $0.originalName, dataSize: $0.size, originalURL: $0.originalURL) }
        guard !added.isEmpty else { completion?([]); return }
        items += added
        added.forEach { DeckThumbnailCache.shared.prewarm($0.fileURL) }
        notifyObservers()
        completion?(added)
    }

    /// Background queue only. Converts HEIC/TIFF/BMP to PNG, copies everything else as-is.
    private static func importFile(_ source: URL, into dir: URL, index: Int) -> PreparedFile? {
        let ext = source.pathExtension.lowercased()
        if convertToPNG.contains(ext) {
            guard let png = CGImageSourceCreateWithURL(source as CFURL, nil).flatMap(pngData(from:)) else { return nil }
            return write(png, ext: "png", into: dir, index: index, originalName: source.lastPathComponent)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = dir.appendingPathComponent("item_\(index)_\(UUID().uuidString.prefix(6)).\(ext.isEmpty ? "png" : ext)")
        guard (try? FileManager.default.copyItem(at: source, to: target)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
        return PreparedFile(url: target, size: size, originalName: source.lastPathComponent, originalURL: source)
    }

    private static func write(_ data: Data, ext: String, into dir: URL, index: Int, originalName: String?) -> PreparedFile? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = dir.appendingPathComponent("item_\(index)_\(UUID().uuidString.prefix(6)).\(ext)")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return PreparedFile(url: target, size: data.count, originalName: originalName)
    }

    /// Full-size PNG with the EXIF rotation applied (iPhone photos store rotation as metadata, which many apps that
    /// receive a PNG ignore), via ImageIO, which is safe off the main thread.
    static func pngData(from source: CGImageSource) -> Data? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // apply rotation
            kCGImageSourceThumbnailMaxPixelSize: max(w, h)      // full size
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    // MARK: - GIF editing

    /// Moves a downloaded video into this session's folder so the GIF editor can use it later. It then goes away with
    /// its item, with Clear Que, or with the 24 h purge (never kept indefinitely). Returns nil if the move failed.
    /// shortcut: keeps every download (direct .mp4 links up to 150 MB each) until its GIF leaves Que or the 24 h purge;
    /// add a size cap if temp-folder use ever becomes a complaint.
    public func adoptSourceVideo(_ url: URL) -> URL? {
        let target = sessionDirectory.appendingPathComponent("source_\(UUID().uuidString.prefix(8)).\(url.pathExtension)")
        guard (try? FileManager.default.moveItem(at: url, to: target)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        return target
    }

    /// Swaps an item's image for `data` in place: same id, position, name and source video, so nothing is duplicated
    /// or reordered. The old file stays on disk for a minute (an app may still be reading a drop of it, as in `clear()`).
    /// Returns nil, leaving the item untouched, if it's no longer in Que or the new file couldn't be written.
    @discardableResult
    public func replaceImage(of id: UUID, with data: Data, extension fileExt: String) -> DeckItem? {
        guard !data.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let old = items[index]
        let target = sessionDirectory.appendingPathComponent("item_\(index + 1)_\(UUID().uuidString.prefix(6)).\(fileExt)")
        guard (try? data.write(to: target, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        let item = DeckItem(id: old.id, createdAt: old.createdAt, type: old.type, fileURL: target,
                            originalFileName: old.originalFileName, dataSize: data.count, sourceVideoURL: old.sourceVideoURL)
        items[index] = item
        DeckThumbnailCache.shared.evict(old.fileURL)
        DeckThumbnailCache.shared.prewarm(item.fileURL)
        notifyObservers()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60.0) {
            try? FileManager.default.removeItem(at: old.fileURL)
        }
        return item
    }

    /// Deletes an item's file and, if Que downloaded it, its source video (a video copied from Finder is the user's own).
    private func deleteFiles(of item: DeckItem) {
        DeckThumbnailCache.shared.evict(item.fileURL)
        try? FileManager.default.removeItem(at: item.fileURL)
        if let source = item.sourceVideoURL, owns(source) { try? FileManager.default.removeItem(at: source) }
    }

    @discardableResult
    public func remove(id: UUID) -> DeckItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        deleteFiles(of: item)
        notifyObservers()
        return item
    }

    /// Removes several items at once (deck preview multi-select), notifying observers a single time.
    public func remove(ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        removed.forEach(deleteFiles(of:))
        notifyObservers()
    }

    public func clear() {
        let oldSessionDirectory = self.sessionDirectory
        clearCount += 1
        items.removeAll()
        DeckThumbnailCache.shared.removeAll()
        
        let sessionId = UUID().uuidString
        let base = baseDirectory
        self.sessionDirectory = base.appendingPathComponent("session_\(sessionId)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.sessionDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        
        notifyObservers()

        // Keep previously dropped files on disk for 60 seconds so destination apps
        // (WhatsApp, Google Slides, Chrome, Finder) can asynchronously read and upload them!
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60.0) {
            try? FileManager.default.removeItem(at: oldSessionDirectory)
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: sessionDirectory)
    }
}

