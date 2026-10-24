// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import SwiftUI

/// Floating picker for a Pinterest board's pins. Opens where the pill was, closes on Esc, a click outside,
/// or after Add. Keyboard (⌘A, Return, Esc) only works while it is open: it is a key-capable panel,
/// so no global key monitoring is needed.
final class BoardPickerPanel: NSPanel {
    var onAdd: (([PinterestBoardPin]) -> Void)?
    var onClose: (() -> Void)?

    private let model: BoardPickerModel
    private var clickOutsideMonitor: Any?
    private var isClosing = false
    /// Clips the (fixed-size) SwiftUI content while the panel morphs to and from the pill.
    private let morphContainer = AppearanceTrackingView()
    /// The badge's glass and still edge light (2.10.1), same as the preview grid; the SwiftUI content sits clear on top.
    private let glassView = NSVisualEffectView()
    private let bevel = BevelView()
    private var hostingView: NSHostingView<BoardPickerView>!
    /// Where to collapse to on close: the pill's frame, or nil when no pill is showing (then shrink to a dot).
    var collapseTarget: (() -> NSRect?)?
    private static let morphCurve = CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)   // quick, soft landing

    static let columns = 5
    static let tile: CGFloat = 72
    static let gap: CGFloat = 6
    static let inset: CGFloat = 16
    static var gridWidth: CGFloat { CGFloat(columns) * tile + CGFloat(columns - 1) * gap + inset * 2 }
    /// The grid uses overlay scroll bars (see OverlayScrollers), which float over the content and take no width.
    static var width: CGFloat { gridWidth }

    init(model: BoardPickerModel) {
        self.model = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = BoardPickerView(
            model: model,
            onAdd: { [weak self] in self?.onAdd?(model.selectedPins) },
            onCancel: { [weak self] in self?.close() }
        )
        hostingView = NSHostingView(rootView: view)
        morphContainer.wantsLayer = true
        morphContainer.layer?.masksToBounds = true
        morphContainer.layer?.cornerCurve = .continuous
        glassView.blendingMode = .withinWindow
        glassView.state = .active
        glassView.autoresizingMask = [.width, .height]
        morphContainer.addSubview(glassView)
        bevel.cornerRadius = 14
        bevel.light = CGVector(dx: 1, dy: -1)   // top-left and bottom-right edges, like the badge and preview
        bevel.autoresizingMask = [.maxXMargin, .minYMargin]
        morphContainer.addSubview(bevel)
        morphContainer.addSubview(hostingView)
        morphContainer.layer?.borderWidth = 1
        morphContainer.onAppearanceChange = { [weak self] in self?.applyLook() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.applyLook() }
        applyLook()
        contentView = morphContainer
    }

    private func applyLook() {
        let dark = morphContainer.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        glassView.material = dark ? .hudWindow : .popover
        glassView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        morphContainer.layer?.backgroundColor = DeckHUDView.glassTint(dark: dark).cgColor
        let edge = DeckHUDView.glassHairline(dark: dark)
        morphContainer.layer?.borderColor = (DeckHUDView.strongEdges ? edge : edge.withAlphaComponent(0.06)).cgColor
        bevel.isDark = dark
        bevel.strength = dark ? 0.5 : 1
        bevel.needsDisplay = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { close() }

    /// Grid height: up to 4½ rows visible (the half row signals that it scrolls).
    private func preferredHeight(screen: NSRect) -> CGFloat {
        let expected = min(max(model.board.pinCount, model.pins.count), model.batchLimit)
        let rows = max(1, Int(ceil(Double(expected) / Double(Self.columns))))
        let visibleRows = rows > 4 ? 4.5 : CGFloat(rows)
        let grid = visibleRows * Self.tile + (ceil(visibleRows) - 1) * Self.gap + Self.inset * 2
        let chrome: CGFloat = 56 + 52    // header + footer
        return min(grid + chrome, screen.height * 0.7)
    }

    /// Opens out of the pill: starts as the pill's own shape at its left corner and grows to full size.
    func present(near anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let bounds = screen.visibleFrame
        let size = NSSize(width: Self.width, height: preferredHeight(screen: bounds))
        // Left-anchored on the pill: same left edge and top edge, growing right and down.
        var x = anchor.minX
        var y = anchor.maxY - size.height
        if y < bounds.minY + 8 { y = anchor.minY }   // not enough room below: grow upwards instead
        x = max(bounds.minX + 8, min(x, bounds.maxX - size.width - 8))
        y = max(bounds.minY + 8, min(y, bounds.maxY - size.height - 8))
        let finalFrame = NSRect(origin: NSPoint(x: x, y: y), size: size)

        // Content is laid out once at its final size and pinned to the top-left; the container only clips it,
        // so nothing re-lays out during the animation.
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.maxXMargin, .minYMargin]

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let start = reduceMotion ? finalFrame : anchor
        setFrame(start, display: false)
        hostingView.setFrameOrigin(NSPoint(x: 0, y: start.height - size.height))
        bevel.frame = hostingView.frame
        morphContainer.layer?.cornerRadius = reduceMotion ? 14 : min(start.height / 2, 14)
        hostingView.alphaValue = reduceMotion ? 1 : 0
        alphaValue = reduceMotion ? 0 : 1
        hasShadow = false
        makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.15 : 0.24
            context.timingFunction = Self.morphCurve
            self.animator().setFrame(finalFrame, display: true)
            self.animator().alphaValue = 1
            self.hostingView.animator().alphaValue = 1
        }, completionHandler: {
            self.hasShadow = true
            self.invalidateShadow()
        })
        if !reduceMotion { animateCornerRadius(to: 14, duration: 0.24, curve: Self.morphCurve) }

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func animateCornerRadius(to radius: CGFloat, duration: TimeInterval, curve: CAMediaTimingFunction) {
        guard let layer = morphContainer.layer else { return }
        let animation = CABasicAnimation(keyPath: "cornerRadius")
        animation.fromValue = layer.cornerRadius
        animation.toValue = radius
        animation.duration = duration
        animation.timingFunction = curve
        layer.add(animation, forKey: "morphRadius")
        layer.cornerRadius = radius
    }

    /// Collapses back into the pill (or, with no pill showing, into a dot at the top-left that fades out).
    override func close() {
        guard !isClosing, isVisible else { return }
        isClosing = true
        if let monitor = clickOutsideMonitor { NSEvent.removeMonitor(monitor); clickOutsideMonitor = nil }

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let pill = collapseTarget?()
        let target = pill ?? NSRect(x: frame.minX, y: frame.maxY - 28, width: 28, height: 28)
        hasShadow = false

        let curve = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.8, 0.4)   // ease-in: accelerate into the pill
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0.12 : 0.2
            context.timingFunction = curve
            if !reduceMotion { self.animator().setFrame(target, display: true) }
            self.hostingView.animator().alphaValue = 0
            // Into a live pill: stay opaque so the pill takes over seamlessly. Otherwise fade away.
            if pill == nil || reduceMotion { self.animator().alphaValue = 0 }
        }, completionHandler: {
            self.orderOut(nil)
            self.isClosing = false
            self.onClose?()
        })
        if !reduceMotion { animateCornerRadius(to: target.height / 2, duration: 0.2, curve: curve) }
    }
}

// MARK: - View

struct BoardPickerView: View {
    @ObservedObject var model: BoardPickerModel
    let onAdd: () -> Void
    let onCancel: () -> Void

    private var count: Int { model.selection.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                // Images, then GIFs (video pins). Headers only when both kinds are present.
                VStack(alignment: .leading, spacing: 0) {
                    let images = model.pins.filter { !$0.isVideo }
                    let gifs = model.pins.filter { $0.isVideo }
                    let showHeaders = !images.isEmpty && !gifs.isEmpty
                    pinSection("Images", images, offset: 0, showHeader: showHeaders)
                    pinSection("GIFs", gifs, offset: images.count, showHeader: showHeaders)
                        .padding(.top, showHeaders && !gifs.isEmpty ? 14 : 0)
                }
                .padding(BoardPickerPanel.inset)
                .background(OverlayScrollerStyle())   // thin floating scroll bar, no track taking width

                if model.isLoading {
                    ProgressView().controlSize(.small).padding(.bottom, 16)
                } else if model.hasMore {
                    Button("Load More Pins") { model.loadNextBatch() }
                        .controlSize(.small)
                        .padding(.bottom, 16)
                } else if model.isShortOfBoard {
                    // Pinterest ended the board early; let the user ask again rather than being stuck.
                    Button("Try Loading More") { model.retryFromStart() }
                        .controlSize(.small)
                        .help("Pinterest stopped early. Ask it again for the rest of this board.")
                        .padding(.bottom, 16)
                }
            }
            Divider()
            footer
        }
        .frame(width: BoardPickerPanel.width)
    }

    @ViewBuilder
    private func pinSection(_ title: String, _ pins: [PinterestBoardPin], offset: Int, showHeader: Bool) -> some View {
        if !pins.isEmpty {
            if showHeader {
                HStack(spacing: 6) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(pins.count)").font(.subheadline).monospacedDigit().foregroundStyle(.tertiary)
                }
                .padding(.bottom, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            // Flexible columns keep the tiles square at whatever width the grid gets.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: BoardPickerPanel.gap),
                                     count: BoardPickerPanel.columns),
                      spacing: BoardPickerPanel.gap) {
                ForEach(Array(pins.enumerated()), id: \.element.id) { index, pin in
                    PinTile(pin: pin, position: offset + index + 1, isSelected: model.selection.contains(pin.id),
                            isInDeck: model.pinsInDeck.contains(pin.id)) {
                        model.toggle(pin, extendingRange: NSEvent.modifierFlags.contains(.shift))
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.board.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(model.allSelected ? "Select None" : "Select All") {
                model.allSelected ? model.selectNone() : model.selectAll()
            }
            .buttonStyle(.borderless)
            .disabled(model.pins.isEmpty)

            // ⌘A always selects everything (the visible button toggles, so it can't own the shortcut).
            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, BoardPickerPanel.inset)
        .frame(height: 56)
    }

    private var statusText: String {
        let selected = count == 1 ? "1 selected" : "\(count) selected"
        let inDeck = model.pins.filter { model.pinsInDeck.contains($0.id) }.count
        return inDeck > 0 ? "\(selected), \(inDeck) already in Que" : selected
    }

    private var subtitle: String {
        if model.pins.isEmpty && model.isLoading { return "Getting pins…" }
        let loaded = model.pins.count
        let pins = loaded == 1 ? "1 pin" : "\(loaded) pins"
        if model.hasMore { return "\(pins) loaded of about \(model.board.pinCount)" }
        // Pinterest's count includes hidden/removed pins, so only flag a clear shortfall.
        if model.board.pinCount > loaded + 5 { return "\(loaded) of about \(model.board.pinCount) pins available" }
        return pins
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            Spacer()
            Button(count > 0 ? "Add \(count) to Que" : "Add to Que", action: onAdd)
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
                .help("Add the selected pins to Que")
        }
        .padding(.horizontal, BoardPickerPanel.inset)
        .frame(height: 52)
    }
}

private struct PinTile: View {
    let pin: PinterestBoardPin
    let position: Int
    let isSelected: Bool
    let isInDeck: Bool
    let toggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)

    var body: some View {
        // Pinterest's dominant colour fills the tile until the thumbnail arrives, so the grid fills in calmly.
        Rectangle()
            .fill(Color(hex: pin.dominantColor) ?? Color.primary.opacity(0.08))
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                AsyncImage(url: pin.thumbnailURL) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            )
            .clipShape(shape)
        .overlay(alignment: .bottomLeading) {
            if pin.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .padding(4)
            }
        }
        .overlay(alignment: .topLeading) {   // top-left: clear of the ▶ badge and the selection check
            if isInDeck {
                Text("In Que")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .font(.system(size: 15))
                    .padding(4)
            }
        }
        .overlay(
            shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                               lineWidth: isSelected ? 2 : 0.5)
        )
        .opacity(isSelected ? 1 : 0.55)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
        .contentShape(shape)
        .onTapGesture(perform: toggle)
        .help(pin.title ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pin.title ?? "Pin \(position)")
        .accessibilityValue([pin.isVideo ? "Video" : nil, isInDeck ? "Already in Que" : nil]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { toggle() }
    }
}

private extension Color {
    /// "#52554c" → Color. Nil for anything else.
    init?(hex: String?) {
        guard var s = hex?.trimmingCharacters(in: .whitespaces), s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
