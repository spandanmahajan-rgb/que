// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// The deck preview (⌥-click on the pill). Same design system as the Pinterest board picker: native popover glass,
/// a title header, and a grid of uniform square, aspect-filled thumbnails. Opens out of the pill's left corner and
/// collapses back into it. Closes on: ⌥ + click, clicking outside, cursor wandering away (>90pt), or deck emptying.
public final class DeckPreviewPanel: NSPanel {
    // Shared metrics with BoardPickerPanel so the two read as one family.
    private static let tile: CGFloat = 72
    private static let gap: CGFloat = 6
    private static let inset: CGFloat = 16
    private static let headerHeight: CGFloat = 56
    private static let footerHeight: CGFloat = 44
    private static let cornerRadius: CGFloat = 14
    private static let maxColumns = 5
    private static let morphCurve = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)

    /// Clips everything to the rounded shape while the panel morphs to and from the pill.
    private let morphContainer = AppearanceTrackingView()
    /// The badge's glass (2.10.1): black in dark mode, white in light mode (blending stays .withinWindow per invariant).
    private let glassView = NSVisualEffectView()
    /// The badge's still edge light, softer here. Sized to the final panel and pinned top-left like the content, so it
    /// is drawn once per size and the morph just reveals it.
    private let bevel = BevelView()
    /// Header + grid, laid out at the final size and pinned top-left so nothing re-lays out mid-morph.
    private let contentContainer = NSView()
    private let titleLabel = NSTextField(labelWithString: "Que")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let selectButton = PanelPushButton(isPrimary: false)   // "Select All" / "Select None", like the board picker
    private let removeButton = FirstMouseButton()   // trash: removes the selected images
    /// Make GIF bar under the grid, shown while 2+ images are selected: seconds per image + the button.
    private let footerSeparator = NSBox()
    private let secondsControl = FirstMouseSegmentedControl(labels: ["1s", "2s", "3s"], trackingMode: .selectOne,
                                                            target: nil, action: nil)
    private let makeGIFButton = PanelPushButton(isPrimary: true)
    private var isMakingGIF = false
    /// Multi-select: click toggles a tile, ⇧-click selects a range, clicking empty space clears.
    private var selectedIDs: Set<UUID> = []
    private var lastClickedIndex: Int?
    private var cells: [PreviewThumbnailCell] = []
    private let scrollView = NSScrollView()
    private let gridView = FlippedView()
    private weak var queueManager: DeckQueueManager?

    public var onClose: (() -> Void)?
    /// An Update GIF that failed after the preview closed (nobody is looking at the editor's own message).
    public var onEditFailedWhileClosed: (() -> Void)?
    /// Where to collapse to on close (the pill's frame). Falls back to a pill-sized rect at the grid's centre.
    public var collapseTarget: (() -> NSRect?)?
    private var clickOutsideMonitor: Any?
    private var isClosing = false
    private var openedAt: TimeInterval = 0
    /// True while a single thumbnail is being dragged out: the preview must not close under the drag.
    private var isDraggingOut = false
    private let dismissDistance: CGFloat = 90.0
    /// The "Edit GIF" state (the preview expands into it); nil while showing the grid.
    private var editor: GIFSegmentEditorView?

    public init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 140, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        setupViews()
    }

    deinit { removeClickOutsideMonitor() }

    private func setupViews() {
        morphContainer.wantsLayer = true
        morphContainer.layer?.masksToBounds = true
        morphContainer.layer?.cornerCurve = .continuous
        morphContainer.layer?.cornerRadius = Self.cornerRadius
        contentView = morphContainer

        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.autoresizingMask = [.width, .height]
        morphContainer.addSubview(glassView)

        bevel.cornerRadius = Self.cornerRadius
        bevel.light = CGVector(dx: 1, dy: -1)   // still light on the top-left and bottom-right edges (wider than the badge's so it shows on straight edges)
        bevel.autoresizingMask = [.maxXMargin, .minYMargin]
        morphContainer.addSubview(bevel)
        morphContainer.layer?.borderWidth = 1
        morphContainer.onAppearanceChange = { [weak self] in self?.applyLook() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.applyLook() }
        applyLook()

        contentContainer.autoresizingMask = [.maxXMargin, .minYMargin]   // pinned top-left while the panel morphs
        morphContainer.addSubview(contentContainer)

        titleLabel.font = NSFont.preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .labelColor
        subtitleLabel.font = NSFont.preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabelColor
        for label in [titleLabel, subtitleLabel] {
            label.lineBreakMode = .byTruncatingTail
            contentContainer.addSubview(label)
        }
        separator.boxType = .separator
        contentContainer.addSubview(separator)

        selectButton.target = self
        selectButton.action = #selector(selectAllClicked)
        contentContainer.addSubview(selectButton)

        removeButton.isBordered = false
        removeButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(textStyle: .body))
        removeButton.imagePosition = .imageOnly
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.target = self
        removeButton.action = #selector(removeSelectedClicked)
        contentContainer.addSubview(removeButton)

        footerSeparator.boxType = .separator
        contentContainer.addSubview(footerSeparator)
        secondsControl.selectedSegment = 0
        secondsControl.controlSize = .small
        secondsControl.sizeToFit()
        secondsControl.toolTip = "How long each image shows"
        secondsControl.setAccessibilityLabel("Seconds per image")
        contentContainer.addSubview(secondsControl)
        makeGIFButton.title = "Make GIF"
        makeGIFButton.sizeToFit()
        makeGIFButton.target = self
        makeGIFButton.action = #selector(makeGIFClicked)
        contentContainer.addSubview(makeGIFButton)

        gridView.onEmptyClick = { [weak self] in self?.setSelection([]) }

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        OverlayScrollers.enforce(on: scrollView)   // thin floating scroll bar; no track taking width
        scrollView.documentView = gridView
        contentContainer.addSubview(scrollView)
    }

    public override var canBecomeKey: Bool { return false }
    public override var canBecomeMain: Bool { return false }

    private func applyLook() {
        let dark = morphContainer.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        glassView.material = dark ? .hudWindow : .popover
        glassView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        morphContainer.layer?.backgroundColor = DeckHUDView.glassTint(dark: dark).cgColor
        let edge = DeckHUDView.glassHairline(dark: dark)
        morphContainer.layer?.borderColor = (DeckHUDView.strongEdges ? edge : edge.withAlphaComponent(0.06)).cgColor
        bevel.isDark = dark
        bevel.strength = dark ? 0.5 : 1   // the badge's full light looked too strong on a panel this size
        bevel.needsDisplay = true
    }

    public override func sendEvent(_ event: NSEvent) {
        // ⌥-click closes the preview, except on a thumbnail or a header button: ⌥ is often still held from the
        // ⌥-click that opened it, and selecting/dragging/removing shouldn't require letting go first.
        if event.type == .leftMouseDown && event.modifierFlags.contains(.option) && !isOnSelectableControl(event) {
            close()
            return
        }
        super.sendEvent(event)
    }

    private func isOnSelectableControl(_ event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return false }
        if hit !== gridView && hit.isDescendant(of: gridView) { return true }   // a thumbnail or its ✕
        if let editor = editor, hit.isDescendant(of: editor) { return true }
        return hit === selectButton || hit === removeButton || hit === makeGIFButton || hit.isDescendant(of: secondsControl)
    }

    // MARK: - Layout

    private struct Layout {
        let columns: Int
        let rows: Int
        let size: NSSize          // whole panel
        let gridHeight: CGFloat   // visible grid area
        let scrolls: Bool
    }

    /// 3–5 columns (narrow decks don't get a header squeezed into one column), up to 4½ rows visible
    /// before the grid scrolls (the half row signals it), exactly like the board picker.
    private static func isGIF(_ item: DeckItem) -> Bool { item.fileURL.pathExtension.lowercased() == "gif" }
    private static let sectionHeaderHeight: CGFloat = 22
    private static let sectionGap: CGFloat = 12

    /// Images first, then GIFs (deck order inside each). Headers only when both kinds are present.
    private func sections(of items: [DeckItem]) -> (groups: [(title: String, items: [(deckIndex: Int, item: DeckItem)])], showHeaders: Bool) {
        let entries = items.enumerated().map { (deckIndex: $0.offset, item: $0.element) }
        let images = entries.filter { !Self.isGIF($0.item) }
        let gifs = entries.filter { Self.isGIF($0.item) }
        let groups = [("Images", images), ("GIFs", gifs)].filter { !$0.1.isEmpty }
        return (groups, groups.count > 1)
    }

    private func layout(for items: [DeckItem]) -> Layout {
        let count = items.count
        let columns = min(max(count, 3), Self.maxColumns)
        let (groups, showHeaders) = sections(of: items)
        let rowCounts = groups.map { max(1, Int(ceil(Double($0.items.count) / Double(columns)))) }
        let rows = rowCounts.reduce(0, +)
        let scrolls = rows > 4
        let extras = showHeaders ? CGFloat(groups.count) * Self.sectionHeaderHeight + CGFloat(groups.count - 1) * Self.sectionGap : 0
        let visibleRows: CGFloat = scrolls ? 4.5 : CGFloat(rows)
        let gridHeight = visibleRows * Self.tile + (ceil(visibleRows) - 1) * Self.gap + Self.inset * 2 + extras
        // Overlay scroll bars float over the grid's 16pt margin, so no width is reserved for them.
        let width = CGFloat(columns) * Self.tile + CGFloat(columns - 1) * Self.gap + Self.inset * 2
        let height = Self.headerHeight + 1 + gridHeight + (showsFooter ? Self.footerHeight + 1 : 0)
        return Layout(columns: columns, rows: rows, size: NSSize(width: width, height: height),
                      gridHeight: gridHeight, scrolls: scrolls)
    }

    /// Height of the whole scrolling document for `items` (sections, headers, gaps), so the grid view can match it.
    private func documentHeight(for items: [DeckItem], columns: Int) -> CGFloat {
        let (groups, showHeaders) = sections(of: items)
        var h = Self.inset
        for (i, group) in groups.enumerated() {
            let rows = max(1, Int(ceil(Double(group.items.count) / Double(columns))))
            if showHeaders { h += Self.sectionHeaderHeight }
            h += CGFloat(rows) * Self.tile + CGFloat(rows - 1) * Self.gap
            if i < groups.count - 1 { h += Self.sectionGap }
        }
        return h + Self.inset
    }

    private func visibleBounds(containing point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// Lays out header + grid inside `contentContainer` for `layout` (container coordinates, y up).
    private func layoutContent(_ layout: Layout) {
        let size = layout.size
        let headerTop = size.height
        titleLabel.sizeToFit()
        subtitleLabel.sizeToFit()
        updateHeaderControls()
        let buttonsWidth = headerButtonsWidth()
        let textWidth = size.width - Self.inset * 2 - buttonsWidth - 8
        layoutHeaderButtons(panelWidth: size.width, headerTop: headerTop)
        let titleH = titleLabel.frame.height, subH = subtitleLabel.frame.height
        let blockH = titleH + 2 + subH
        let blockTop = headerTop - (Self.headerHeight - blockH) / 2
        titleLabel.frame = NSRect(x: Self.inset, y: blockTop - titleH, width: textWidth, height: titleH)
        subtitleLabel.frame = NSRect(x: Self.inset, y: blockTop - titleH - 2 - subH, width: textWidth, height: subH)
        separator.frame = NSRect(x: 0, y: headerTop - Self.headerHeight - 1, width: size.width, height: 1)
        let footerH = showsFooter ? Self.footerHeight + 1 : 0
        scrollView.frame = NSRect(x: 0, y: footerH, width: size.width, height: layout.gridHeight)
        for view in [footerSeparator, secondsControl, makeGIFButton] as [NSView] { view.isHidden = !showsFooter }
        footerSeparator.frame = NSRect(x: 0, y: Self.footerHeight, width: size.width, height: 1)
        let midY = Self.footerHeight / 2
        secondsControl.frame.origin = NSPoint(x: Self.inset, y: (midY - secondsControl.frame.height / 2).rounded())
        makeGIFButton.frame.origin = NSPoint(x: size.width - Self.inset - makeGIFButton.frame.width,
                                             y: (midY - makeGIFButton.frame.height / 2).rounded())
    }

    /// 2+ selected: there is something to make a GIF from.
    private var showsFooter: Bool { selectedIDs.count >= 2 }

    // MARK: - Selection

    private func setSelection(_ ids: Set<UUID>) {
        let hadFooter = showsFooter
        selectedIDs = ids
        for cell in cells { cell.isSelected = ids.contains(cell.item.id) }
        if ids.isEmpty { lastClickedIndex = nil }
        updateHeaderControls()
        guard let qm = queueManager, !qm.isEmpty else { return }
        if showsFooter != hadFooter { resize(to: layout(for: qm.items), rebuildingGrid: false) }
        else { layoutContent(layout(for: qm.items)) }
    }

    private func cellClicked(_ cell: PreviewThumbnailCell, index: Int, modifiers: NSEvent.ModifierFlags) {
        var ids = selectedIDs
        if modifiers.contains(.shift), let anchor = lastClickedIndex, anchor < cells.count {
            for i in min(anchor, index)...max(anchor, index) { ids.insert(cells[i].item.id) }
        } else if ids.contains(cell.item.id) {
            ids.remove(cell.item.id)
        } else {
            ids.insert(cell.item.id)
        }
        lastClickedIndex = index
        setSelection(ids)
    }

    /// Cells that travel together when `cell` is dragged: the whole selection if it's part of it, else just it.
    private func dragGroup(for cell: PreviewThumbnailCell) -> [PreviewThumbnailCell] {
        // Deck order (the order things joined Que), whatever section they sit in on screen.
        let order = queueManager?.items.map { $0.id } ?? []
        let selected = cells.filter { $0.isSelected }.sorted {
            (order.firstIndex(of: $0.item.id) ?? 0) < (order.firstIndex(of: $1.item.id) ?? 0)
        }
        return cell.isSelected ? selected : [cell]
    }

    @objc private func selectAllClicked() {
        let all = Set(cells.map { $0.item.id })
        setSelection(selectedIDs.count == all.count ? [] : all)
    }

    /// Makes a GIF from the selection (deck order) and adds it to Que; the originals stay. Keeps going if the preview closes.
    @objc private func makeGIFClicked() {
        guard !isMakingGIF, let qm = queueManager, showsFooter else { return }
        let urls = qm.items.filter { selectedIDs.contains($0.id) }.map { $0.fileURL }
        let seconds = Double(secondsControl.selectedSegment + 1)
        isMakingGIF = true
        makeGIFButton.isEnabled = false
        VideoToGIFConverter.shared.makeSlideshow(imageURLs: urls, secondsEach: seconds) { [weak self, weak qm] data in
            guard let self = self else { return }
            self.isMakingGIF = false
            self.makeGIFButton.isEnabled = true
            guard let data = data else {
                self.subtitleLabel.stringValue = "This GIF couldn't be made. Try again."
                return
            }
            guard let qm = qm else { return }
            if !qm.isFull, self.queueManager === qm {   // the GIF's arrival refreshes the grid, without the bar
                self.selectedIDs = []
                self.lastClickedIndex = nil
            }
            qm.add(imageData: data, extension: "gif")   // full: Que shows its own notice
        }
    }

    @objc private func removeSelectedClicked() {
        guard !selectedIDs.isEmpty else { return }
        let ids = selectedIDs
        selectedIDs = []
        lastClickedIndex = nil
        queueManager?.remove(ids: ids)   // one queue change; the observer calls refresh() once
    }

    private func updateHeaderControls() {
        let total = queueManager?.count ?? 0
        let selected = selectedIDs.count
        subtitleLabel.stringValue = selected > 0
            ? "\(selected) of \(total) selected"
            : "\(total) in Que"
        selectButton.title = (selected == total && total > 0) ? "Select None" : "Select All"
        selectButton.sizeToFit()
        removeButton.isHidden = selected == 0
        let what = selected == 1 ? "1 image" : "\(selected) images"
        removeButton.toolTip = "Remove \(what) from Que"
        removeButton.setAccessibilityLabel("Remove \(what) from Que")
    }

    private func headerButtonsWidth() -> CGFloat {
        selectButton.frame.width + (removeButton.isHidden ? 0 : 22 + 10)
    }

    private func layoutHeaderButtons(panelWidth: CGFloat, headerTop: CGFloat) {
        let midY = headerTop - Self.headerHeight / 2
        var x = panelWidth - Self.inset
        if !removeButton.isHidden {
            removeButton.frame = NSRect(x: x - 22, y: midY - 11, width: 22, height: 22)
            x -= 22 + 10
        }
        let h = selectButton.frame.height
        selectButton.frame.origin = NSPoint(x: x - selectButton.frame.width, y: (midY - h / 2).rounded())
    }

    private func rebuildGrid(_ layout: Layout) {
        gridView.subviews.forEach { $0.removeFromSuperview() }
        cells = []
        guard let queueManager = queueManager, !queueManager.isEmpty else { return }
        let items = queueManager.items
        let count = items.count
        // Keep the selection for images still in the deck.
        selectedIDs.formIntersection(Set(items.map { $0.id }))
        updateHeaderControls()

        // Fixed 72pt tiles; the overlay scroll bar floats in the right margin rather than taking width.
        let tile = Self.tile
        let docHeight = documentHeight(for: items, columns: layout.columns)
        let gridWidth = CGFloat(layout.columns) * tile + CGFloat(layout.columns - 1) * Self.gap + Self.inset * 2
        gridView.frame = NSRect(x: 0, y: 0, width: gridWidth, height: max(docHeight, layout.gridHeight))

        let (groups, showHeaders) = sections(of: items)
        var y = Self.inset
        var index = 0   // position on screen (selection ranges follow it); deck order still rules drag-out
        for (g, group) in groups.enumerated() {
            if showHeaders {
                gridView.addSubview(sectionHeader(group.title, count: group.items.count,
                                                  frame: NSRect(x: Self.inset, y: y, width: gridWidth - Self.inset * 2, height: Self.sectionHeaderHeight)))
                y += Self.sectionHeaderHeight
            }
            for (n, entry) in group.items.enumerated() {
            let item = entry.item
            let col = n % layout.columns, row = n / layout.columns
            let cell = PreviewThumbnailCell(
                item: item, position: entry.deckIndex + 1, total: count,
                frame: NSRect(x: Self.inset + CGFloat(col) * (tile + Self.gap),
                              y: y + CGFloat(row) * (tile + Self.gap),   // flipped: row 0 at the top
                              width: tile, height: tile)
            )
            let shownIndex = index
            // Deleting only mutates the queue; the queue observer calls refresh() once.
            cell.onDelete = { [weak self] deleted in self?.queueManager?.remove(id: deleted.id) }
            cell.onDragOut = { [weak self] dragging in self?.isDraggingOut = dragging }
            cell.onClick = { [weak self] clicked, modifiers in self?.cellClicked(clicked, index: shownIndex, modifiers: modifiers) }
            cell.dragGroup = { [weak self] dragged in self?.dragGroup(for: dragged) ?? [dragged] }
            cell.onEdit = { [weak self] edited in self?.openEditor(for: edited) }
            cell.isSelected = selectedIDs.contains(item.id)
            cells.append(cell)
            gridView.addSubview(cell)
            index += 1
            }
            let rows = max(1, Int(ceil(Double(group.items.count) / Double(layout.columns))))
            y += CGFloat(rows) * tile + CGFloat(rows - 1) * Self.gap + (g < groups.count - 1 ? Self.sectionGap : 0)
        }
    }

    /// "Images 12" / "GIFs 4": a quiet title and a fainter count (no extra chrome).
    private func sectionHeader(_ title: String, count: Int, frame: NSRect) -> NSTextField {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor])
        text.append(NSAttributedString(string: "  \(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor]))
        let label = NSTextField(labelWithAttributedString: text)
        label.frame = frame
        label.setAccessibilityRole(.staticText)
        return label
    }

    // MARK: - Open / Morph / Refresh / Close

    /// Opens by growing out of the pill's left corner into the full preview.
    public func open(from sourceRect: NSRect, queueManager: DeckQueueManager, onClose: (() -> Void)? = nil) {
        guard !queueManager.isEmpty else { return }
        self.queueManager = queueManager
        self.onClose = onClose
        isClosing = false
        removeEditor()
        openedAt = CACurrentMediaTime()
        selectedIDs = []   // each opening starts with nothing selected
        lastClickedIndex = nil

        let layout = self.layout(for: queueManager.items)
        let targetSize = layout.size
        let bounds = visibleBounds(containing: NSPoint(x: sourceRect.midX, y: sourceRect.midY))

        // Left-anchored on the pill (same left and top edge), growing right and down; clamped to the screen.
        var targetX = sourceRect.minX
        targetX = max(bounds.minX + 8, min(targetX, bounds.maxX - targetSize.width - 8))
        var targetY = sourceRect.maxY - targetSize.height
        if targetY < bounds.minY + 8 { targetY = sourceRect.minY }
        targetY = max(bounds.minY + 8, min(targetY, bounds.maxY - targetSize.height - 8))
        let targetFrame = NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize)

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduceMotion ? targetFrame : sourceRect
        setFrame(start, display: false)
        glassView.frame = morphContainer.bounds
        contentContainer.frame = NSRect(x: 0, y: start.height - targetSize.height,
                                        width: targetSize.width, height: targetSize.height)
        bevel.frame = contentContainer.frame
        layoutContent(layout)
        rebuildGrid(layout)
        scrollView.contentView.scroll(to: .zero)
        if layout.scrolls { scrollView.flashScrollers() }   // briefly show the bar so it's clear the grid scrolls

        contentContainer.alphaValue = reduceMotion ? 1 : 0
        alphaValue = reduceMotion ? 0 : 1
        hasShadow = false
        orderFrontRegardless()
        installClickOutsideMonitor()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.15 : 0.24
            context.timingFunction = Self.morphCurve
            self.animator().setFrame(targetFrame, display: true)
            self.animator().alphaValue = 1
            self.contentContainer.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            self?.hasShadow = true
            self?.invalidateShadow()
        })
    }

    /// Re-syncs the grid with the queue (new copy, ✕ delete, clear). Closes if the deck is empty.
    public func refresh() {
        guard isVisible, !isClosing else { return }
        guard let qm = queueManager, !qm.isEmpty else {
            close()
            return
        }
        if let editor = editor {
            // The grid catches up when the editor closes; only leave it if its GIF left Que (cleared, removed).
            if qm.items.contains(where: { $0.id == editor.item.id }) { return }
            closeEditor()
            return
        }

        selectedIDs.formIntersection(Set(qm.items.map { $0.id }))   // before the layout: it decides the Make GIF bar
        resize(to: self.layout(for: qm.items), rebuildingGrid: true)
    }

    /// Animates the panel to `layout`'s size, keeping its top-left corner.
    private func resize(to layout: Layout, rebuildingGrid: Bool) {
        let size = layout.size
        let targetFrame = anchoredFrame(for: size)

        // Top-aligned against the current height; autoresizing lands it at y = 0 when the resize finishes.
        contentContainer.frame = NSRect(x: 0, y: frame.height - size.height, width: size.width, height: size.height)
        bevel.frame = contentContainer.frame
        layoutContent(layout)
        if rebuildingGrid { rebuildGrid(layout) }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = Self.morphCurve
            self.animator().setFrame(targetFrame, display: true)
        }, completionHandler: { [weak self] in self?.invalidateShadow() })
    }

    /// Called every ~16ms from CursorHUDPanel's tracking timer: dismiss if the cursor wanders off.
    public func tick() {
        guard isVisible, !isClosing, !isDraggingOut else { return }
        if CACurrentMediaTime() - openedAt < 0.35 { return }
        if editor != nil && NSEvent.pressedMouseButtons != 0 { return }   // dragging a handle past the edge
        let mouse = NSEvent.mouseLocation
        if !frame.insetBy(dx: -dismissDistance, dy: -dismissDistance).contains(mouse) {
            close()
        }
    }

    /// Collapses back into the pill (or, with Reduce Motion, fades out in place).
    public override func close() {
        guard isVisible, !isClosing else { return }
        isClosing = true
        removeClickOutsideMonitor()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        editor?.tearDown()   // stop playback now; a GIF already being made still replaces the old one
        let pill = collapseTarget?()
        let collapseRect = reduceMotion ? frame : (pill ?? NSRect(x: frame.minX, y: frame.maxY - 28, width: 58, height: 28))
        hasShadow = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.12 : 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.8, 0.4)   // accelerate into the pill
            self.animator().setFrame(collapseRect, display: true)
            self.contentContainer.animator().alphaValue = 0
            self.editor?.animator().alphaValue = 0
            // Into the pill: stay opaque so the pill takes over seamlessly. Otherwise fade away.
            if pill == nil || reduceMotion { self.animator().alphaValue = 0 }
        }, completionHandler: { [weak self] in
            guard let self = self else { return }
            self.orderOut(nil)
            self.removeEditor()
            self.alphaValue = 1.0
            self.contentContainer.alphaValue = 1.0
            self.isClosing = false
            let cb = self.onClose
            self.onClose = nil
            cb?()
        })
    }

    /// Keeps the top-left corner where it is (the panel grows right and down), clamped to the screen.
    private func anchoredFrame(for size: NSSize) -> NSRect {
        let bounds = visibleBounds(containing: NSPoint(x: frame.midX, y: frame.midY))
        let x = max(bounds.minX + 8, min(frame.minX, bounds.maxX - size.width - 8))
        let y = max(bounds.minY + 8, min(frame.maxY - size.height, bounds.maxY - size.height - 8))
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: - Edit GIF

    /// Expands the preview into the GIF editor: the grid fades out while the panel grows to the editor's size.
    private func openEditor(for item: DeckItem) {
        guard editor == nil, !isClosing, GIFSegmentEditing.canEdit(item) else { return }
        let editor = GIFSegmentEditorView(item: item)
        editor.onCancel = { [weak self] in self?.closeEditor() }
        editor.onConfirm = { [weak self, weak editor] segment in
            guard let self = self, let editor = editor else { return }
            self.confirmEdit(editor, segment: segment)
        }
        self.editor = editor
        let size = GIFSegmentEditorView.size
        editor.autoresizingMask = [.maxXMargin, .minYMargin]   // pinned top-left while the panel morphs, like the grid
        editor.frame = NSRect(x: 0, y: frame.height - size.height, width: size.width, height: size.height)
        editor.alphaValue = 0
        morphContainer.addSubview(editor)
        morph(to: anchoredFrame(for: size), showing: editor, hiding: contentContainer)
    }

    /// Back to the grid (after Cancel, a successful update, or the GIF leaving Que).
    private func closeEditor() {
        guard let editor = editor else { return }
        self.editor = nil
        editor.tearDown()
        guard let qm = queueManager, !qm.isEmpty else { editor.removeFromSuperview(); close(); return }
        let layout = self.layout(for: qm.items)
        contentContainer.frame = NSRect(x: 0, y: frame.height - layout.size.height,
                                        width: layout.size.width, height: layout.size.height)
        layoutContent(layout)
        rebuildGrid(layout)
        morph(to: anchoredFrame(for: layout.size), showing: contentContainer, hiding: editor) { [weak editor] in
            editor?.removeFromSuperview()
        }
    }

    /// Cross-fades two states while the panel resizes. A new morph takes over from wherever the last one was.
    private func morph(to target: NSRect, showing: NSView, hiding: NSView, completion: (() -> Void)? = nil) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        bevel.frame = NSRect(x: 0, y: frame.height - target.height, width: target.width, height: target.height)
        if reduceMotion { setFrame(target, display: true) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.15 : 0.24
            context.timingFunction = Self.morphCurve
            if !reduceMotion { self.animator().setFrame(target, display: true) }
            showing.animator().alphaValue = 1
            hiding.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            completion?()
            self?.invalidateShadow()
        })
    }

    /// Makes the new GIF; the old one stays in Que until it exists. Closing the preview meanwhile doesn't stop it.
    private func confirmEdit(_ editor: GIFSegmentEditorView, segment: GIFSegment) {
        guard let qm = queueManager else { return }
        editor.setProcessing(true)
        GIFSegmentEditing.replaceGIF(of: editor.item.id, in: qm, segment: segment) { [weak self, weak qm] updated in
            guard let self = self else { return }
            guard self.editor === editor else {   // closed or moved on meanwhile
                if updated == nil, qm?.items.contains(where: { $0.id == editor.item.id }) == true { self.onEditFailedWhileClosed?() }
                return
            }
            if updated != nil || qm?.items.contains(where: { $0.id == editor.item.id }) != true {
                self.closeEditor()
            } else {
                editor.setProcessing(false)
                editor.showError("This GIF couldn't be updated. Try again, or choose a shorter part.")
            }
        }
    }

    private func removeEditor() {
        editor?.tearDown()
        editor?.removeFromSuperview()
        editor = nil
    }

    // MARK: - Click-outside

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self = self, !self.isDraggingOut else { return }
            if CACurrentMediaTime() - self.openedAt < 0.15 { return }
            self.close()
        }
    }

    private func removeClickOutsideMonitor() {
        if let m = clickOutsideMonitor {
            NSEvent.removeMonitor(m)
            clickOutsideMonitor = nil
        }
    }
}

/// Grid document view with row 0 at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    /// A click on the grid's empty space (between or around tiles).
    var onEmptyClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onEmptyClick?() }
}

// MARK: - Thumbnail cell

/// NSButton that fires on the first click even though the panel never becomes key.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class FirstMouseSegmentedControl: NSSegmentedControl {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A push button that looks like the board picker's "Add to Que" in a panel that never becomes key, where AppKit would
/// draw a real push button in its inactive grey. Primary: accent fill, white text. Secondary: a quiet grey surface.
/// Both brighten on hover and darken while pressed.
final class PanelPushButton: NSButton {
    private let isPrimary: Bool
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    private var trackingArea: NSTrackingArea?

    init(isPrimary: Bool) {
        self.isPrimary = isPrimary
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        font = NSFont.preferredFont(forTextStyle: .body)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var title: String { didSet { updateTitleColor() } }
    override var isEnabled: Bool { didSet { alphaValue = isEnabled ? 1 : 0.45; if !isEnabled { isHovered = false } } }

    /// Fits the title with 10 pt padding each side, 22 pt tall (a regular push button's height).
    override func sizeToFit() {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        setFrameSize(NSSize(width: ceil(width) + 20, height: 22))
    }

    private func updateTitleColor() {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: isPrimary ? NSColor.white : NSColor.labelColor,
            .paragraphStyle: style,
        ])
    }

    override func updateLayer() {
        // Resolved here, where light/dark appearance is current.
        let fill: NSColor
        if isPrimary {
            let accent = NSColor.controlAccentColor
            fill = isPressed ? (accent.blended(withFraction: 0.2, of: .black) ?? accent)
                : isHovered ? (accent.blended(withFraction: 0.1, of: .white) ?? accent) : accent
        } else {
            fill = NSColor.labelColor.withAlphaComponent(isPressed ? 0.2 : isHovered ? 0.14 : 0.09)
        }
        layer?.backgroundColor = fill.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        super.mouseDown(with: event)   // tracks until the mouse goes up, then sends the action if released inside
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { if isEnabled { isHovered = true } }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// One deck item: a square, aspect-filled thumbnail (like the board picker's tiles). Hover shows a remove button.
/// Drag a thumbnail out to drop just that image somewhere; it stays in the deck.
final class PreviewThumbnailCell: NSView, NSDraggingSource {
    let item: DeckItem
    private let position: Int
    private let total: Int
    var onDelete: ((DeckItem) -> Void)?
    /// true when a drag out of this cell starts, false when it ends.
    var onDragOut: ((Bool) -> Void)?
    /// A click without a drag (selects/deselects).
    var onClick: ((PreviewThumbnailCell, NSEvent.ModifierFlags) -> Void)?
    /// The cells dragged together with this one (the selection, or just this cell).
    var dragGroup: ((PreviewThumbnailCell) -> [PreviewThumbnailCell])?
    /// The hover pencil on a GIF made from a video: opens the GIF editor.
    var onEdit: ((DeckItem) -> Void)?
    private var editButton: FirstMouseButton?
    private var mouseDownPoint: NSPoint?
    private let checkmark = NSImageView()
    private var isHovered = false

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            animateCheckmark(isSelected)
            deleteButton.alphaValue = (isHovered && !isSelected) ? 1 : 0
            setAccessibilitySelected(isSelected)
            setAccessibilityValue(accessibilityStateText)
            needsDisplay = true   // border via updateLayer
        }
    }

    /// A quick scale-and-fade so selecting feels tactile; fades only with Reduce Motion.
    private func animateCheckmark(_ on: Bool) {
        let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        if on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = checkmark.layer {
            let b = checkmark.bounds
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)   // pivot on the centre, not the corner
            t = CATransform3DScale(t, 0.85, 0.85, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = t
            grow.toValue = CATransform3DIdentity
            grow.duration = 0.15
            grow.timingFunction = curve
            layer.add(grow, forKey: "select")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = on ? 0.15 : 0.10
            context.timingFunction = curve
            checkmark.animator().alphaValue = on ? 1 : 0
        }
    }

    var thumbnailImage: NSImage {
        (imageLayer.contents as? NSImage) ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
    }

    private var accessibilityStateText: String {
        [isSelected ? "Selected" : nil, gifTag != nil ? "Animated GIF" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    private let imageLayer = CALayer()
    private let deleteButton = FirstMouseButton()
    private var gifTag: NSTextField?
    private var trackingArea: NSTrackingArea?

    init(item: DeckItem, position: Int, total: Int, frame: NSRect) {
        self.item = item
        self.position = position
        self.total = total
        super.init(frame: frame)
        setupView()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5

        // Aspect-fill: every tile is a uniform square crop, whatever the image's proportions.
        imageLayer.frame = bounds
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        // AUDIT: cached downsampled thumbnail (decoded once, pre-warmed on add) instead of a full-size decode.
        let image = DeckThumbnailCache.shared.thumbnail(for: item.fileURL)
            ?? NSImage(contentsOf: item.fileURL)
            ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
        imageLayer.contents = image
        layer?.addSublayer(imageLayer)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Image \(position) of \(total)")
        setAccessibilityHelp("Selects this image. Drag to drop it, or the whole selection; images stay in Que.")
        toolTip = "Click to select. Drag to drop a copy; it stays in Que."

        if item.fileURL.pathExtension.lowercased() == "gif" {
            let tag = Self.badgeLabel("GIF")
            tag.frame.origin = NSPoint(x: 4, y: 4)
            addSubview(tag)
            gifTag = tag
            setAccessibilityValue("Animated GIF")
        }

        // Selected: checkmark top-right (same as the board picker); the hover ✕ hides on selected tiles.
        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor])))
        checkmark.frame = NSRect(x: bounds.width - 19 - 4, y: bounds.height - 19 - 4, width: 19, height: 19)
        checkmark.wantsLayer = true
        checkmark.alphaValue = 0
        checkmark.setAccessibilityElement(false)

        // Remove button: same neutral dark badge style as the picker's tags (not an iOS-style red circle).
        let size: CGFloat = 18
        deleteButton.frame = NSRect(x: bounds.width - size - 4, y: bounds.height - size - 4, width: size, height: size)
        deleteButton.isBordered = false
        deleteButton.wantsLayer = true
        deleteButton.layer?.cornerRadius = size / 2
        deleteButton.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        deleteButton.title = ""
        deleteButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 8, weight: .bold))
        deleteButton.imagePosition = .imageOnly
        deleteButton.contentTintColor = .white
        deleteButton.setAccessibilityLabel("Remove image \(position)")
        deleteButton.toolTip = "Remove from Que"
        deleteButton.alphaValue = 0.0
        deleteButton.target = self
        deleteButton.action = #selector(deleteClicked)
        addSubview(deleteButton)
        addSubview(checkmark)

        // Edit: the same dark circle, bottom-right, only on GIFs whose whole video Que still has.
        if GIFSegmentEditing.canEdit(item) {
            let edit = FirstMouseButton(frame: NSRect(x: bounds.width - size - 4, y: 4, width: size, height: size))
            edit.isBordered = false
            edit.wantsLayer = true
            edit.layer?.cornerRadius = size / 2
            edit.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
            edit.title = ""
            edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
            edit.imagePosition = .imageOnly
            edit.contentTintColor = .white
            edit.setAccessibilityLabel("Edit GIF \(position)")
            edit.toolTip = "Edit GIF"
            edit.alphaValue = 0
            edit.target = self
            edit.action = #selector(editClicked)
            addSubview(edit)
            editButton = edit
        }
    }

    @objc private func editClicked() { onEdit?(item) }

    /// Small white-on-dark capsule label, matching the board picker's "In deck" tag.
    private static func badgeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.sizeToFit()
        label.frame.size = NSSize(width: label.frame.width + 10, height: label.frame.height + 2)
        label.layer?.cornerRadius = label.frame.height / 2
        label.setAccessibilityElement(false)
        return label
    }

    override func updateLayer() {
        // Hairline + placeholder follow light/dark appearance (resolved here, where the appearance is current).
        layer?.borderColor = isSelected ? NSColor.controlAccentColor.cgColor : NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.borderWidth = isSelected ? 2 : 0.5
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    @objc private func deleteClicked() { onDelete?(item) }

    // MARK: Drag one image out

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        mouseDownPoint = nil

        // The whole selection travels together when this tile is part of it (in deck order), like Finder.
        let group = dragGroup?(self) ?? [self]
        let dragItems = group.map { cell -> NSDraggingItem in
            let dragItem = NSDraggingItem(pasteboardWriter: cell.item.fileURL as NSURL)
            dragItem.setDraggingFrame(convert(cell.bounds, from: cell), contents: cell.thumbnailImage)
            return dragItem
        }
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        // Same extra flavour the pill's drag adds, for apps like WhatsApp that read the legacy file list.
        session.draggingPasteboard.setPropertyList(group.map { $0.item.fileURL.path }, forType: .init("NSFilenamesPboardType"))
        onDragOut?(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard mouseDownPoint != nil else { return }   // nil after a drag started
        mouseDownPoint = nil
        onClick?(self, event.modifierFlags)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?(self, [])
        return true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy   // a copy: the image stays in the deck
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragOut?(false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            editButton?.animator().alphaValue = 1.0   // bottom-right: stays clear of the selection checkmark
            if !isSelected { deleteButton.animator().alphaValue = 1.0 }
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            deleteButton.animator().alphaValue = 0.0
            editButton?.animator().alphaValue = 0.0
        }
    }
}

/// Reports system light/dark switches (the preview's root view, so the glass can follow them).
final class AppearanceTrackingView: NSView {
    var onAppearanceChange: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
