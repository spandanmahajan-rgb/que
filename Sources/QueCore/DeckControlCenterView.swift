// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation
import SwiftUI

/// SF Symbols that only exist on newer macOS, with a fallback for older systems (Que runs on macOS 13+).
/// A missing symbol draws nothing, which left Shake to Clear's icon circle empty on macOS 13–15.
enum QueSymbol {
    /// Shake to Clear: "pointer.arrow.motionlines" arrived in macOS 26; "cursorarrow.motionlines" exists since 11.
    // SYMBOL-FALLBACK: pointer.arrow.motionlines
    static let shake: String = NSImage(systemSymbolName: "pointer.arrow.motionlines", accessibilityDescription: nil) != nil
        ? "pointer.arrow.motionlines" : "cursorarrow.motionlines"
}

// MARK: - Popover Material

/// The same material a native macOS popover uses. SwiftUI's `Material.ultraThin` blurred twice as strongly as a real
/// popover (radius 60 vs 30) with a thinner tint, so the panel never quite looked native. Blending stays `.withinWindow`
/// (project invariant); in this transparent panel macOS still frosts what is behind it, exactly like NSPopover.
/// Turns solid automatically when Reduce Transparency is on.
struct PopoverMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .withinWindow
        view.state = .active          // Que is never the active app; keep the glass live anyway
        view.wantsLayer = true
        view.layer?.cornerRadius = 14
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Observable State Model

public final class DeckControlCenterState: ObservableObject {
    @Published public var itemCount: Int = 0
    @Published public var isTrackingPaused: Bool = false
    @Published public var isSmartFilterEnabled: Bool = true
    @Published public var isScreenshotWatcherEnabled: Bool = true
    @Published public var isShakeClearEnabled: Bool = true
    @Published public var isLaunchAtLoginEnabled: Bool = false
    @Published public var isCopiedFeedback: Bool = false
    /// How Que is called over: false = hold ⌥, true = tap ⌃ twice (QueControls).
    @Published public var usesDoubleTap: Bool = QueControls.usesDoubleTap
    /// A newer version waiting to be installed (blue dot), or nil.
    @Published public var availableUpdate: String? = nil

    private weak var queueManager: DeckQueueManager?
    private weak var clipboardWatcher: ClipboardWatcher?
    private weak var screenshotWatcher: ScreenshotWatcher?
    private weak var hudPanel: CursorHUDPanel?
    private var observerToken: UUID?

    /// Lets the menu bar icon show/hide ⏸ whenever tracking is paused or resumed from anywhere.
    public var onTrackingPausedChanged: (() -> Void)?

    public init(
        queueManager: DeckQueueManager? = nil,
        clipboardWatcher: ClipboardWatcher? = nil,
        screenshotWatcher: ScreenshotWatcher? = nil,
        hudPanel: CursorHUDPanel? = nil
    ) {
        self.queueManager = queueManager
        self.clipboardWatcher = clipboardWatcher
        self.screenshotWatcher = screenshotWatcher
        self.hudPanel = hudPanel
        refresh()

        self.observerToken = queueManager?.addObserver { [weak self] _ in
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    public func refresh() {
        self.itemCount = queueManager?.count ?? 0
        self.isTrackingPaused = clipboardWatcher?.isPaused ?? false
        self.isSmartFilterEnabled = clipboardWatcher?.isSmartFilterEnabled ?? true
        self.isScreenshotWatcherEnabled = screenshotWatcher?.isEnabled ?? true
        self.isShakeClearEnabled = hudPanel?.shakeDetector.isEnabled ?? true
        self.isLaunchAtLoginEnabled = LaunchAtLoginManager.shared.isEnabled
        self.availableUpdate = UpdateManager.shared.availableVersion
        self.usesDoubleTap = QueControls.usesDoubleTap
    }

    public func toggleCallStyle() {
        QueControls.usesDoubleTap.toggle()
        usesDoubleTap = QueControls.usesDoubleTap
    }

    public func toggleTracking() {
        let newPaused = !isTrackingPaused
        clipboardWatcher?.isPaused = newPaused
        screenshotWatcher?.isPaused = newPaused
        hudPanel?.isTrackingPaused = newPaused
        isTrackingPaused = newPaused
        onTrackingPausedChanged?()
    }

    public func toggleSmartFilter() {
        let newFilter = !isSmartFilterEnabled
        clipboardWatcher?.isSmartFilterEnabled = newFilter
        isSmartFilterEnabled = newFilter
    }

    public func toggleScreenshots() {
        let newScreenshots = !isScreenshotWatcherEnabled
        screenshotWatcher?.isEnabled = newScreenshots
        isScreenshotWatcherEnabled = newScreenshots
    }

    public func toggleShakeClear() {
        let newShake = !isShakeClearEnabled
        hudPanel?.shakeDetector.isEnabled = newShake
        isShakeClearEnabled = newShake
    }

    public func toggleLaunchAtLogin() {
        let newLaunch = !isLaunchAtLoginEnabled
        LaunchAtLoginManager.shared.setEnabled(newLaunch)
        isLaunchAtLoginEnabled = newLaunch
    }

    public func copyAll() {
        guard let queueManager = queueManager, !queueManager.isEmpty else { return }
        PasteboardWriter.shared.writeToPasteboard(items: queueManager.items)
        withAnimation(.easeInOut(duration: 0.15)) {
            isCopiedFeedback = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            withAnimation(.easeInOut(duration: 0.15)) {
                self?.isCopiedFeedback = false
            }
        }
    }

    public func clearDeck() {
        queueManager?.clear()
        refresh()
    }

    public func checkForUpdates() {
        UpdateManager.shared.checkForUpdates(userInitiated: true)
    }

    public func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Native macOS Dropdown Style Popover (Matched to System Wi-Fi Dropdown & Golden Gate Tokens)

public enum PopoverPage {
    case controls
    case howToUse
}

public struct DeckControlCenterView: View {
    /// Fixed panel height (width 256); matches the How to Use page. Was 350 before Report a Problem; the 2.6.1 layout keeps 372.
    public static let height: CGFloat = 372

    @ObservedObject public var state: DeckControlCenterState
    public var onDismiss: (() -> Void)?
    /// Shown inside a macOS menu (the menu bar Control Center): the menu supplies the glass, corners and border.
    private let inMenu: Bool

    @State public var currentPage: PopoverPage
    @State private var hoveredRow: String? = nil
    @State private var hoveredAction: String? = nil
    @State private var expandedGuideItem: String? = nil
    @State private var hoveredGuideItem: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Page slide normally; a plain cross-fade when Reduce Motion is on.
    private var pageAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 1.0)
    }

    public init(
        state: DeckControlCenterState,
        onDismiss: (() -> Void)? = nil,
        inMenu: Bool = false,
        initialPage: PopoverPage = .controls
    ) {
        self.state = state
        self.onDismiss = onDismiss
        self.inMenu = inMenu
        self._currentPage = State(initialValue: initialPage)
    }

    public var body: some View {
        ZStack {
            if currentPage == .controls {
                controlsPage
                    .frame(width: 256, height: DeckControlCenterView.height)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .leading),
                        removal: .move(edge: .leading)
                    ))
            } else {
                howToUsePage
                    .frame(width: 256, height: DeckControlCenterView.height)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: .trailing),
                        removal: .move(edge: .trailing)
                    ))
            }
        }
        .frame(width: 256, height: DeckControlCenterView.height)
        .clipped()
        .animation(pageAnimation, value: currentPage)
        .modifier(StandaloneGlass(enabled: !inMenu))
    }

    /// Our own popover glass, corners and hairline, for when the view isn't inside a macOS menu.
    private struct StandaloneGlass: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content
                    .background(PopoverMaterialBackground())
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            } else {
                content
            }
        }
    }

    // MARK: - Controls Page (Default Popover View)

    private var controlsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. MASTER HEADER (Matches "Wi-Fi [Toggle]" row in macOS)
            masterHeaderRow
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            dividerView

            // 2. PREFERENCES (one list: the three capture switches, then Launch at Login)
            VStack(spacing: 2) {
                // These only matter while tracking is on, so they fade while paused (they stay adjustable).
                VStack(spacing: 2) {
                    listToggleRow(
                        id: "filter",
                        symbol: "line.3.horizontal.decrease",
                        title: "Smart Filter",
                        isOn: state.isSmartFilterEnabled,
                        action: { state.toggleSmartFilter() }
                    )

                    listToggleRow(
                        id: "screenshots",
                        symbol: "camera.viewfinder",
                        title: "Screenshots",
                        isOn: state.isScreenshotWatcherEnabled,
                        action: { state.toggleScreenshots() }
                    )

                    listToggleRow(
                        id: "shake",
                        symbol: QueSymbol.shake,
                        title: "Shake to Clear",
                        isOn: state.isShakeClearEnabled,
                        action: { state.toggleShakeClear() }
                    )
                }
                .opacity(state.isTrackingPaused ? 0.45 : 1)
                .animation(.easeOut(duration: 0.15), value: state.isTrackingPaused)

                listToggleRow(
                    id: "launch",
                    symbol: "power",
                    title: "Launch at Login",
                    isOn: state.isLaunchAtLoginEnabled,
                    action: { state.toggleLaunchAtLogin() }
                )
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            dividerView
                .padding(.top, 8)

            // 3. DECK ACTIONS (slim row)
            deckActionsRow
                .padding(.horizontal, 14)
                .padding(.top, 8)

            Spacer(minLength: 0)

            dividerView

            // 4. FOOTER (How to Use, More)
            utilityFooter
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Master Header (Title + Master Tracking Toggle)

    private var masterHeaderRow: some View {
        HStack(alignment: .center) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Que")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text(statusSubtitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { state.toggleTracking() }
            .accessibilityHidden(true)   // the switch carries the label and value

            Toggle("Que", isOn: Binding(
                get: { !state.isTrackingPaused },
                set: { _ in state.toggleTracking() }
            ))
            .toggleStyle(MenuSwitchStyle())
            .accessibilityHint("Turn off to pause Que. \(statusSubtitle)")   // keeps VoiceOver's own on/off value
        }
    }

    private var statusSubtitle: String {
        if state.isTrackingPaused {
            return "Que is paused"
        } else if state.itemCount == 0 {
            return "Waiting for its first image"
        } else {
            return "\(state.itemCount) in Que"
        }
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundColor(.secondary)
    }

    // MARK: - Native List Toggle Row (Matches Wi-Fi list row with Golden Gate Liquid Glass badge)

    private func listToggleRow(
        id: String,
        symbol: String,
        title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredRow == id

        return HStack(spacing: 9) {
            // Icon + title + empty space: clicking here toggles too, as before.
            // (Kept separate from the switch so a click on the switch never toggles twice.)
            HStack(spacing: 9) {
                // Liquid Glass circular icon badge
                ZStack {
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 26, height: 26)

                    // Specular highlight rim from Liquid Glass - Small token
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(isOn ? 0.35 : 0.16),
                                    Color.white.opacity(isOn ? 0.08 : 0.03)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                        .frame(width: 26, height: 26)

                    Image(systemName: symbol)
                        .font(.callout.weight(.medium))
                        .foregroundColor(isOn ? .white : Color.secondary)
                }

                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityHidden(true)   // the switch carries the label and on/off value for VoiceOver

            // macOS-style switch (see MenuSwitchStyle): VoiceOver reads on/off
            Toggle(title, isOn: Binding(get: { isOn }, set: { _ in action() }))
                .toggleStyle(MenuSwitchStyle())
        }
        .padding(.horizontal, 6)
        .frame(height: 34)
        .background(isHovered ? Color.primary.opacity(0.07) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredRow = inside ? id : nil
            }
        }
    }

    // MARK: - Deck Actions Row (Liquid Glass compact action buttons)

    private var deckActionsRow: some View {
        HStack(spacing: 6) {
            actionButton(
                id: "copy",
                symbol: state.isCopiedFeedback ? "checkmark" : "doc.on.doc",
                label: state.isCopiedFeedback ? "Copied" : "Copy All",
                isDestructive: false,
                isEnabled: state.itemCount > 0,
                action: { state.copyAll() }
            )

            // How Que is called over; a click switches to the other way (the How to Use page follows).
            actionButton(
                id: "call",
                symbol: nil,   // the key glyphs are the icon
                label: state.usesDoubleTap ? "⌃⌃ Tap" : "⌥ Hold",
                isDestructive: false,
                isEnabled: true,
                isHighlighted: !state.isTrackingPaused,   // blue = the chosen way is working (grey while paused)
                action: { state.toggleCallStyle() }
            )
            .help(state.usesDoubleTap
                  ? "Tap the Control key (⌃) twice to call Que over. Click to hold the Option key (⌥) instead."
                  : "Hold the Option key (⌥) to call Que over. Click to tap the Control key (⌃) twice instead.")
            .accessibilityLabel(state.usesDoubleTap ? "Call Que over: tap the Control key twice" : "Call Que over: hold the Option key")
            .accessibilityHint(state.usesDoubleTap ? "Switches to holding the Option key" : "Switches to tapping the Control key twice")

            actionButton(
                id: "clear",
                symbol: "trash",
                label: "Clear",
                isDestructive: true,
                isEnabled: state.itemCount > 0,
                action: { state.clearDeck() }
            )
        }
        .frame(height: 30)
    }

    private func actionButton(
        id: String,
        symbol: String?,
        label: String,
        isDestructive: Bool,
        isEnabled: Bool,
        isHighlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredAction == id

        let normalBg = isHighlighted ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)
        let hoverBg = isDestructive ? Color.red.opacity(0.12) : Color.primary.opacity(0.09)
        let currentBg = isHovered ? hoverBg : normalBg

        let fgColor: Color
        if !isEnabled {
            fgColor = Color.secondary.opacity(0.4)
        } else if isDestructive && isHovered {
            fgColor = Color.red
        } else if isHighlighted {
            fgColor = Color.accentColor
        } else {
            fgColor = Color.primary
        }

        return Button(action: {
            if isEnabled { action() }
        }) {
            HStack(spacing: 5) {
                if let symbol = symbol {
                    Image(systemName: symbol)
                        .font(.callout.weight(.medium))
                        .foregroundColor(fgColor)
                }

                Text(label)
                    .font(.callout.weight(.medium))
                    .foregroundColor(fgColor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(currentBg)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.10 : 0.05), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredAction = inside ? id : nil
            }
        }
    }

    // MARK: - Utility Footer

    /// Four menu-style rows (icon, title, optional trailing mark), all the same height and hover highlight.
    private var utilityFooter: some View {
        VStack(spacing: 0) {
            footerRow(
                id: "howto", symbol: "questionmark.circle", title: "How to Use",
                trailingChevron: true,
                action: { withAnimation(pageAnimation) { currentPage = .howToUse } }
            )

            footerRow(
                id: "updates", symbol: "arrow.triangle.2.circlepath",
                title: state.availableUpdate.map { "Update to Que \($0)…" } ?? "Check for Updates…",
                showsUpdateDot: state.availableUpdate != nil,
                action: {
                    onDismiss?()
                    state.checkForUpdates()
                }
            )

            footerRow(
                id: "report", symbol: "exclamationmark.bubble", title: "Report a Problem…",
                help: "Opens a short form in your browser",
                action: {
                    onDismiss?()   // close the menu first, then open the form in the browser
                    ProblemReport.open()
                }
            )

            footerRow(
                id: "quit", symbol: "rectangle.portrait.and.arrow.right", title: "Quit",
                help: "Quit Que",
                action: {
                    onDismiss?()   // close the menu first; quitting from inside an open menu is deferred
                    DispatchQueue.main.async { state.quitApp() }
                }
            )
        }
    }

    private func footerRow(
        id: String,
        symbol: String,
        title: String,
        trailingChevron: Bool = false,
        showsUpdateDot: Bool = false,
        help: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.callout.weight(.medium))
                    .foregroundColor(.secondary)
                    .frame(width: 26)   // same column as the icon circles above

                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)

                if showsUpdateDot {
                    // Same blue dot as the menu bar icon; the update window opens from here.
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                }

                Spacer()

                if trailingChevron {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .contentShape(Rectangle())
            .background(hoveredRow == id ? Color.primary.opacity(0.07) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredRow = inside ? id : nil
            }
        }
        .help(help ?? "")
    }

    // MARK: - How to Use Page (Slide-over view with clear instructions & hotkeys)

    private var howToUsePage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with Back button
            HStack {
                Button(action: {
                    withAnimation(pageAnimation) {
                        currentPage = .controls
                    }
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                        Text("Back")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundColor(.accentColor)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(Color.primary.opacity(0.001))
                }
                .buttonStyle(.plain)

                Spacer()

                Text("How to Use")
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)

                Spacer()

                // Invisible spacer for centered title alignment
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                    Text("Back")
                        .font(.callout.weight(.medium))
                }
                .opacity(0)
            }
            .padding(.horizontal, 10)
            .padding(.top, 11)
            .padding(.bottom, 9)

            dividerView

            // Instructions: one line each; click a row to show how it works (one open at a time).
            ScrollViewReader { proxy in
                // No SwiftUI indicators: with a mouse connected SwiftUI lays the rows out ~15pt narrower for a full-size
                // scroll bar, which cut titles off ("Drop on Sli…"). OverlayScrollerStyle adds our thin bar instead.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionHeader("Using Que")
                            .padding(.horizontal, 6)
                            .padding(.top, 8)
                            .padding(.bottom, 4)

                        ForEach(Self.gestureGuide(doubleTap: state.usesDoubleTap)) { instructionRow($0, proxy: proxy) }

                        dividerView
                            .padding(.vertical, 6)

                        sectionHeader("Settings")
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)

                        ForEach(Self.settingsGuide(doubleTap: state.usesDoubleTap)) { instructionRow($0, proxy: proxy) }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 10)
                    .background(OverlayScrollerStyle())   // thin floating scroll bar; never narrows the text
                }
            }
        }
    }

    struct GuideItem: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let badge: String?
        let description: String
    }

    /// Describes only the chosen way of calling Que over (hold ⌥, or tap ⌃ twice), never both.
    static func gestureGuide(doubleTap: Bool) -> [GuideItem] { [
        GuideItem(id: "collect", symbol: "doc.on.doc", title: "Collect Images", badge: "⌘ C",
                  description: "Copy any image from a browser, Finder or a design app (right-click › Copy Image, or ⌘C). It joins Que."),
        GuideItem(id: "screenshots", symbol: "camera.viewfinder", title: "Screenshots", badge: "⌘ ⇧ 4",
                  description: "Take a screenshot as usual. It joins Que instead of landing on your desktop. Que hides while you choose the area."),
        GuideItem(id: "boards", symbol: "rectangle.stack", title: "Pinterest Boards", badge: "Link",
                  description: doubleTap
                    ? "Copy a public Pinterest board link and Que offers to add it. Tap the Control key (⌃) twice, then click Que to pick pins, or click and hold to add them all (up to 100). Pins already in Que are skipped."
                    : "Copy a public Pinterest board link and Que offers to add it. Hold the Option key (⌥) and click Que to pick pins, or click and hold to add them all (up to 100). Pins already in Que are skipped."),
        GuideItem(id: "videos", symbol: "film.stack", title: "Videos to GIF", badge: "Link",
                  description: "Copy a Pinterest video pin, a link ending in .mp4 or .mov, or a video file in Finder. Que turns it into a short looping GIF. To pick a different moment, open the preview, point at the GIF and click the pencil. YouTube isn't supported."),
        GuideItem(id: "drop", symbol: "arrow.down.doc", title: "Drop on Slides", badge: doubleTap ? "⌃⌃ + Drag" : "⌥ + Drag",
                  description: doubleTap
                    ? "Tap the Control key (⌃) twice and Que sticks to your pointer (its dot glows). Drag it onto Slides, Keynote, Figma or a chat like WhatsApp and let go: all your images land at once. To send Que back without dropping, tap the Control key twice again."
                    : "Hold the Option key (⌥) and Que jumps under your pointer. Drag it onto Slides, Keynote, Figma or a chat like WhatsApp and let go: all your images land at once."),
        GuideItem(id: "grid", symbol: "square.grid.2x2", title: "Preview Grid", badge: doubleTap ? "⌃⌃ + Click" : "⌥ + Click",
                  description: (doubleTap ? "Tap the Control key (⌃) twice, then click Que to see everything in it." : "Hold the Option key (⌥) and click Que to see everything in it.")
                    + " Click images to select them (⇧-click selects a range), then drag them out or remove them with the trash button. Dragging copies them; they stay in Que."),
        GuideItem(id: "shake", symbol: QueSymbol.shake, title: "Shake to Clear", badge: "Shake",
                  description: "Move the pointer quickly left and right a few times to clear Que."),
        GuideItem(id: "messages", symbol: "text.bubble", title: "Que Messages", badge: nil,
                  description: doubleTap
                    ? "Que grows to show what's happening, like a board being added. When a message offers two choices, tap the Control key (⌃) twice, then click Que for the first, or click and hold for the second."
                    : "Que grows to show what's happening, like a board being added. When a message offers two choices, hold the Option key (⌥) and click Que for the first, or click and hold for the second."),
    ] }

    static func settingsGuide(doubleTap: Bool) -> [GuideItem] { [
        GuideItem(id: "switch", symbol: "power", title: "Pause Que", badge: nil,
                  description: "The switch at the top pauses Que. While paused, the dot turns orange, new copies and screenshots are skipped, and Que ignores clicks, shakes and \(doubleTap ? "Control key taps" : "the Option key"), so you can work freely in apps like Illustrator."),
        GuideItem(id: "filter", symbol: "line.3.horizontal.decrease", title: "Smart Filter", badge: nil,
                  description: "Skips shapes and text copied in Figma, Photoshop and Illustrator, so only real images join Que."),
        GuideItem(id: "screenshots-setting", symbol: "camera.viewfinder", title: "Screenshots", badge: nil,
                  description: "Turn off to keep screenshots out of Que."),
        GuideItem(id: "shake-setting", symbol: QueSymbol.shake, title: "Shake to Clear", badge: nil,
                  description: "Turn off if you shake the pointer while working and don't want Que cleared."),
        GuideItem(id: "login", symbol: "power.circle", title: "Launch at Login", badge: nil,
                  description: "Starts Que in the menu bar when you log in."),
        GuideItem(id: "actions", symbol: "slider.horizontal.3", title: "Action Bar", badge: nil,
                  description: "Copy All, Clear, and how Que comes to your pointer: hold the Option key (⌥), or tap the Control key (⌃) twice. Click it to switch; these tips follow your choice."),
        GuideItem(id: "menu", symbol: "menubar.rectangle", title: "Quick Menu", badge: "Right-click",
                  description: "Right-click the menu bar icon to copy, clear, pause, check for updates, report a problem or quit without opening this panel."),
        GuideItem(id: "privacy", symbol: "lock", title: "Privacy", badge: nil,
                  description: "Copies from password managers are ignored. Images stay in a private temporary folder, never in your own folders, and Que empties when you quit."),
    ] }

    /// Expand/collapse motion for a guide row; a plain fade when Reduce Motion is on.
    private var rowAnimation: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 1.0)
    }

    private func instructionRow(_ item: GuideItem, proxy: ScrollViewProxy) -> some View {
        let isExpanded = expandedGuideItem == item.id
        let isHovered = hoveredGuideItem == item.id

        return Button(action: {
            withAnimation(rowAnimation) {
                expandedGuideItem = isExpanded ? nil : item.id
            }
            // Bring an opened row near the bottom fully into view once it has grown.
            if !isExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(rowAnimation) { proxy.scrollTo(item.id) }
                }
            }
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    // Liquid Glass icon badge (Golden Gate token style)
                    ZStack {
                        Circle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 25, height: 25)

                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                            .frame(width: 25, height: 25)

                        Image(systemName: item.symbol)
                            .font(.callout.weight(.medium))
                            .foregroundColor(Color.secondary)
                    }

                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    if let badge = item.badge {
                        KeycapBadgeView(badge)
                    }

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(.secondary.opacity(isHovered || isExpanded ? 0.9 : 0.5))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }

                if isExpanded {
                    Text(item.description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                        .padding(.leading, 35)   // aligns with the title, past the icon
                        .padding(.bottom, 2)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(isHovered || isExpanded ? Color.primary.opacity(isHovered ? 0.065 : 0.04) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(item.id)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                if inside {
                    hoveredGuideItem = item.id
                } else if hoveredGuideItem == item.id {
                    hoveredGuideItem = nil
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(isExpanded ? item.description : "")
        .accessibilityHint(isExpanded ? "Hides the explanation" : "Shows how it works")
    }

    // MARK: - Divider

    private var dividerView: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 10)
    }
}

// MARK: - Keycap Badge View (Mac HIG breathable keycaps)

public struct KeycapBadgeView: View {
    public let badge: String

    public init(_ badge: String) {
        self.badge = badge
    }

    public var body: some View {
        HStack(spacing: 2.5) {
            ForEach(tokens(for: badge), id: \.self) { token in
                if token == "+" {
                    Text("+")
                        .font(.system(size: 8.5, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.8))
                } else {
                    Text(token)
                        .font(.system(size: token.count == 1 ? 10.5 : 9.5, weight: .medium, design: .default))
                        .fixedSize()
                        .foregroundColor(.primary.opacity(0.88))
                        .padding(.horizontal, token.count == 1 ? 4.5 : 5.5)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                }
            }
        }
    }

    private func tokens(for string: String) -> [String] {
        switch string {
        case "⌘ C":
            return ["⌘", "C"]
        case "⌘ ⇧ 4":
            return ["⌘", "⇧", "4"]
        case "⌥ + Drag":
            return ["⌥", "+", "Drag"]
        case "⌥ + Click":
            return ["⌥", "+", "Click"]
        case "⌃⌃":
            return ["⌃", "⌃"]
        case "⌃⌃ + Drag":
            return ["⌃⌃", "Drag"]   // one cap for the pair, no "+": keeps "Drop on Slides" from truncating
        case "⌃⌃ + Click":
            return ["⌃⌃", "Click"]
        default:
            return [string]
        }
    }
}


// MARK: - Menu switch

/// The macOS mini switch, drawn by Que. The Control Center lives in a menu, and Que never becomes the active app
/// when it opens (so it doesn't take focus from your work); AppKit then draws every system switch in its inactive grey,
/// even when on (overriding the tint or `controlActiveState` doesn't change that). This matches the system mini switch:
/// 26 x 15 pt capsule, accent when on, the system's translucent grey track when off, white knob with a soft shadow.
struct MenuSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack(alignment: on ? .trailing : .leading) {
            Capsule()
                .fill(on ? Color.accentColor : Color.primary.opacity(0.12))
                .overlay(Capsule().strokeBorder(Color.primary.opacity(on ? 0 : 0.1), lineWidth: 0.5))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.25), radius: 0.75, y: 0.5)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                .padding(1)
        }
        .frame(width: 26, height: 15)
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Capsule())
        .onTapGesture {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { configuration.isOn.toggle() }
        }
        // VoiceOver sees a real switch (label, on/off, toggle action), not the drawing.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}
