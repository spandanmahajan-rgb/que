// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

public final class PasteboardWriter {
    public static let shared = PasteboardWriter()

    public init() {}

    @discardableResult
    public func writeToPasteboard(items: [DeckItem]) -> Bool {
        return writeToPasteboard(fileURLs: items.map(\.exportURL))
    }

    /// Puts these files on the clipboard (for ⌘V into chats, Slides, Finder...), marked as CursorDeck's own
    /// so the clipboard watcher doesn't collect them again.
    @discardableResult
    public func writeToPasteboard(fileURLs urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let fileURLs: [NSURL] = urls.map { $0 as NSURL }
        let success = pasteboard.writeObjects(fileURLs)

        let paths = urls.map { $0.path }
        pasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

        pasteboard.setString("cursordeck", forType: .init("com.cursordeck.internal-marker"))
        return success
    }
}
