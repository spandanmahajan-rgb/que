// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

public final class CursorHUDPanel: NSPanel, DeckHUDViewDelegate {
    public let queueManager: DeckQueueManager
    public let shakeDetector = ShakeDetector()
    public let previewPanel = DeckPreviewPanel()

    private let hudView: DeckHUDView
    private var trackingTimer: Timer?
    private var trackingLink: AnyObject?          // CADisplayLink on macOS 14+ (typed loosely so the macOS 13 build compiles)
    private var lastTickTime: CFTimeInterval = 0
    /// Time since the previous tick in 60 fps frames (1 at a steady 60 fps), so a late tick doesn't make the badge lurch.
    private var tickScale: CGFloat = 1
    private var previousCount: Int = 0
    private var wasMagnetHeld = false

    /// "Tap ⌃ twice" (see QueControls): ⌃⌃ snaps the pill under the pointer until ⌃⌃ again or a drop; ⌥ then no
    /// longer snaps, so ⌥-drag duplicates in other apps.
    private var isDoubleTapMode: Bool { QueControls.usesDoubleTap }
    private var controlDoubleTap = ControlDoubleTap()
    public var isTapSnapped = false {   // public so tests can set it without two real ⌃ taps
        didSet { if isTapSnapped != oldValue { hudView.isTapSnapped = isTapSnapped } }
    }

    /// The user is catching the pill: ⌥ held, or snapped by ⌃⌃ in double-tap mode.
    private var isCatching: Bool {
        isDoubleTapMode ? isTapSnapped : CGEventSource.flagsState(.hidSystemState).contains(.maskAlternate)
    }

    private func pollDoubleTap() {
        guard isDoubleTapMode else { isTapSnapped = false; return }
        if controlDoubleTap.poll() && !isTrackingPaused { isTapSnapped.toggle() }
    }

    private var isDragging = false
    private var isDismissing = false

    private let badgeHeight: CGFloat = 28.0

    private var badgeWidth: CGFloat {
        // Dot + count, ~10pt visible padding each side: 40pt for one digit, 8pt more per extra digit.
        let digits = String(queueManager.count).count
        return 40.0 + CGFloat(max(digits, 1) - 1) * 8.0
    }

    // MARK: Notice state
    private var notice: PillNotice?
    private var noticeToken = 0
    /// True while the pill shrinks back to its dot and fades after the last notice on an empty deck.
    private var isCollapsing = false
    /// The smallest pill: just the dot, a 28pt circle. Notices grow out of it and collapse back into it.
    private static let dotSize = NSSize(width: 28, height: 28)

    /// Size the pill is animating towards: the notice's size while one shows, otherwise the count badge.
    private var targetSize: NSSize {
        if isCollapsing { return Self.dotSize }
        if let notice = notice { return hudView.preferredSize(for: notice) }
        if isWorking && queueManager.isEmpty { return Self.dotSize }   // just the bouncing dot until the GIF lands
        return NSSize(width: badgeWidth, height: badgeHeight)
    }

    /// The pill is on screen while the deck has items, a notice is showing, or it is collapsing away.
    private var isActive: Bool { !queueManager.isEmpty || notice != nil || isCollapsing || isWorking }

    /// A video → GIF or a Pinterest pin is on its way: the dot turns grey and bounces until it lands (Que stays on
    /// screen meanwhile, as just the dot when it's empty).
    public var isWorking = false {
        didSet {
            guard isWorking != oldValue else { return }
            hudView.isWorking = isWorking
            refreshHUD()
        }
    }

    /// Hides the pill and stops it following the cursor (used while the board picker is open).
    public var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            alphaValue = isSuspended ? 0 : 1
            applyMousePassThrough()
            if !isSuspended { refreshHUD() }
        }
    }

    /// Tracking paused (Control Center switch / menu): the pill stays and follows the pointer but does nothing:
    /// no magnet snap, no shake-to-clear, and clicks/drags pass through to the app underneath (e.g. ⌘-clicking
    /// vectors in Illustrator). Resuming restores everything.
    public var isTrackingPaused = false {
        didSet {
            guard isTrackingPaused != oldValue else { return }
            applyMousePassThrough()
            hudView.isPaused = isTrackingPaused   // orange dot while paused
            if isTrackingPaused { isTapSnapped = false }
            if isTrackingPaused && previewPanel.isVisible { previewPanel.close() }
        }
    }

    /// Scrolling: the pill sits under the pointer while ⌥ is held, so it used to swallow ⌥ + scroll (zoom in
    /// Illustrator, Figma, Maps). Scrolling is never something the pill needs, so the first wheel event it sees
    /// makes the pill click-through until the wheel has been quiet for a moment; the app underneath then gets the
    /// rest. (The very first tick is lost: events can't be re-posted without a permission.)
    private static let scrollQuietPeriod: TimeInterval = 0.35
    private var scrollPassThroughUntil: Date?
    private var scrollMonitor: Any?

    private func noteScroll() {
        scrollPassThroughUntil = Date().addingTimeInterval(Self.scrollQuietPeriod)
        applyMousePassThrough()
    }

    private func applyMousePassThrough() {
        if let until = scrollPassThroughUntil, until <= Date() { scrollPassThroughUntil = nil }
        ignoresMouseEvents = isSuspended || isTrackingPaused || scrollPassThroughUntil != nil
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel { noteScroll(); return }
        super.sendEvent(event)
    }

    /// The pill's frame if it is on screen (also while suspended behind the picker), else nil.
    /// Panels that open out of the pill collapse back into this.
    public var pillFrameIfShowing: NSRect? { isVisible ? frame : nil }

    public init(queueManager: DeckQueueManager) {
        self.queueManager = queueManager
        let initialWidth: CGFloat = 40.0
        let rect = NSRect(x: 100, y: 100, width: initialWidth, height: badgeHeight)

        self.hudView = DeckHUDView(frame: NSRect(origin: .zero, size: rect.size))

        super.init(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .popUpMenu
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false          // Never auto-hide on app switch
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        hudView.queueManager = queueManager
        hudView.delegate = self
        contentView = hudView

        // The preview grid collapses back into the pill wherever it currently is.
        previewPanel.collapseTarget = { [weak self] in self?.frame }
        previewPanel.onEditFailedWhileClosed = { [weak self] in self?.show(.gifEditFailed()) }

        // Wire up Shake gesture: Discard ENTIRE deck (Clear All)
        shakeDetector.onShakeDetected = { [weak self] in
            guard let self = self, !self.queueManager.isEmpty, !self.isDragging, !self.isDismissing else { return }
            if self.previewPanel.isVisible {
                self.previewPanel.close()
            }
            self.isDismissing = true
            self.hudView.triggerDismissPuffAnimation {
                self.queueManager.clear()
                self.isDismissing = false
                self.refreshHUD()
            }
        }

        queueManager.addObserver { [weak self] _ in
            guard let self = self else { return }
            // Keep an open preview in sync (new copy, ✕ delete, deck cleared)
            if self.previewPanel.isVisible { self.previewPanel.refresh() }
            self.refreshHUD()
        }

        // Re-surface the pill whenever the user switches apps.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isActive, !self.isDragging, !self.isDismissing, !self.isSuspended else { return }
            if !self.previewPanel.isVisible {
                self.orderFrontRegardless()
            }
        }

        // While click-through, scroll events go to other apps: a global monitor keeps the quiet period running.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            guard let self, self.scrollPassThroughUntil != nil else { return }
            self.noteScroll()
        }

        refreshHUD()
    }

    public override var canBecomeKey: Bool { return false }
    public override var canBecomeMain: Bool { return false }

    /// AUDIT: the 60 fps timer now only runs while the deck has items. It used to fire ~62x/second
    /// forever (just to hide an already-hidden panel), which keeps the CPU awake while idle.
    /// refreshHUD() starts/stops it as the deck fills and empties; calling this on an empty deck is a no-op.
    public func startTracking(interval: TimeInterval = 0.016) {
        guard trackingTimer == nil, trackingLink == nil, isActive else { return }
        lastTickTime = CACurrentMediaTime()
        if #available(macOS 14.0, *) {
            // Synced to the screen the badge is on; capped at 60 fps so shake detection behaves the same on 120 Hz screens.
            let link = displayLink(target: self, selector: #selector(trackingTick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            trackingLink = link
        } else {
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.trackingTick() }
            RunLoop.main.add(timer, forMode: .common)
            trackingTimer = timer
        }
        startScreenshotWatch()
    }

    @objc private func trackingTick() {
        let now = CACurrentMediaTime()
        tickScale = min(max(CGFloat(now - lastTickTime) * 60, 0.25), 3)
        lastTickTime = now
        updatePosition()
    }

    /// A per-frame smoothing factor (tuned at 60 fps) adjusted for this tick's real length.
    private func perTick(_ factor: CGFloat) -> CGFloat { 1 - pow(1 - factor, tickScale) }

    public func stopTracking() {
        if #available(macOS 14.0, *) { (trackingLink as? CADisplayLink)?.invalidate() }
        trackingLink = nil
        trackingTimer?.invalidate()
        trackingTimer = nil
        stopScreenshotWatch()
    }

    // MARK: - Screenshots

    // The pill sits next to the cursor, so it used to land in ⌘⇧4 / ⌘⇧5 screenshots. While macOS's screenshot
    // overlay is on screen (a full-screen window owned by `screencapture`, there before the image is taken), the
    // pill fades out and is excluded from capture; it comes back when the overlay closes. Detected from window
    // owner names, which need no permission. Outside screenshots the pill stays visible, including in screen
    // sharing and recordings (demos). ⌘⇧3 can't be caught: it captures before any overlay appears.
    private var screenshotTimer: Timer?
    private var isHiddenForScreenshot = false
    private var screenshotOverlayGoneAt: CFTimeInterval?

    private func startScreenshotWatch() {
        guard screenshotTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in self?.checkForScreenshotOverlay() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        screenshotTimer = timer
    }

    private func stopScreenshotWatch() {
        screenshotTimer?.invalidate()
        screenshotTimer = nil
        if isHiddenForScreenshot { setHiddenForScreenshot(false) }
    }

    /// True for macOS's screenshot UI windows: the `screencapture` selection overlay and the ⌘⇧5 toolbar.
    /// (Owner name "screencapture" is the process name, which isn't localized; the toolbar is matched by bundle id.)
    public static func isScreenshotWindow(ownerName: String?, bundleID: String?, layer: Int) -> Bool {
        guard layer >= 1000 else { return false }   // screenshot UI sits far above normal windows (seen: 1498/1499)
        return ownerName == "screencapture" || bundleID == "com.apple.screencaptureui"
    }

    private func checkForScreenshotOverlay() {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let overlayUp = windows.contains { window in
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            guard layer >= 1000 else { return false }
            let pid = (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) }
            let bundleID = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
            return Self.isScreenshotWindow(ownerName: window[kCGWindowOwnerName as String] as? String,
                                           bundleID: bundleID, layer: layer)
        }
        if overlayUp {
            screenshotOverlayGoneAt = nil
            if !isHiddenForScreenshot { setHiddenForScreenshot(true) }
        } else if isHiddenForScreenshot {
            // Wait a moment after the overlay closes so a just-finished capture never includes the returning pill.
            let now = CACurrentMediaTime()
            if let goneAt = screenshotOverlayGoneAt {
                if now - goneAt > 0.4 { setHiddenForScreenshot(false) }
            } else {
                screenshotOverlayGoneAt = now
            }
        }
    }

    private func setHiddenForScreenshot(_ hidden: Bool) {
        isHiddenForScreenshot = hidden
        screenshotOverlayGoneAt = nil
        sharingType = hidden ? .none : .readOnly   // belt and braces: excluded from the capture itself
        // The pill's *content* fades (not the window), so this never fights the picker/collapse window fades.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = hidden ? 0.08 : 0.18
            self.hudView.animator().alphaValue = hidden ? 0 : 1
        }
    }

    private func updatePosition() {
        defer { hudView.syncLight() }
        if scrollPassThroughUntil != nil { applyMousePassThrough() }   // restore clicks once the wheel is quiet
        pollDoubleTap()
        // Hide only when there is nothing to show (empty deck, no notice) and no drag is in flight
        guard isActive else {
            isTapSnapped = false
            if isVisible && !isDragging { orderOut(nil) }
            return
        }

        guard !isDragging, !isDismissing, !isSuspended else { return }

        // While the preview grid is open, let it auto-dismiss if the cursor wanders off
        if previewPanel.isVisible {
            previewPanel.tick()
            return
        }

        // ⌥ pulls the pill under the pointer like a magnet: ⌥ + drag = burst-drop, ⌥ + click = open preview grid.
        // (⌘ used to as well; dropped so ⌘-click in browsers and design apps never lands on the pill.)
        // Paused: the pill only follows; ⌥ no longer pulls it under the pointer.
        let isMagnetHeld = !isTrackingPaused && isCatching

        let currentOrigin = frame.origin

        // Grow/shrink smoothly towards the target size (notice text or count), riding the same 60fps loop
        // as the position so the two never fight. Reduce Motion: jump straight to the new size.
        let target = targetSize
        var currentW = frame.width
        var currentH = frame.height
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            currentW = target.width
            currentH = target.height
        } else {
            currentW += (target.width - currentW) * perTick(0.3)
            currentH += (target.height - currentH) * perTick(0.3)
            // Snap the last point: with whole-point rounding below, a 1pt gap would otherwise never close.
            if abs(target.width - currentW) < 1.5 { currentW = target.width }
            if abs(target.height - currentH) < 1.5 { currentH = target.height }
        }
        currentW = currentW.rounded()
        currentH = currentH.rounded()
        // Only force a redraw when the size actually changes; moving alone needs no redraw.
        let sizeChanged = currentW != frame.width || currentH != frame.height

        // Freeze while a click on the pill itself is held, so clicks don't jitter. A press anywhere else (selecting
        // text, dragging a window or a file) keeps it following, so it never sits frozen in the way.
        // It still grows in place, so a notice that changes under the finger (click and hold) isn't cut off.
        if NSEvent.pressedMouseButtons != 0 && (hudView.isPressed || isMagnetHeld) {
            if sizeChanged { setFrame(NSRect(x: currentOrigin.x, y: currentOrigin.y, width: currentW, height: currentH), display: true) }
            return
        }

        let mousePos = NSEvent.mouseLocation

        // Feed horizontal movement into ShakeDetector to detect rapid cursor shake
        if !isTrackingPaused { shakeDetector.observe(x: mousePos.x) }

        // Find current display frame (taking Dock and Menu Bar into account)
        let screen = NSScreen.screens.first { NSMouseInRect(mousePos, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let bounds = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        // MARK: - Screen Edge Clamping & Flip
        var targetX: CGFloat
        var targetY: CGFloat

        if isMagnetHeld {
            // Magnet Snap: under the pointer, clamped safely to screen edges. The pointer sits over the pill's
            // left part (its centre for the normal badge), so a wider notice grows to the right of it.
            targetX = mousePos.x - min(currentW / 2, 29)
            targetY = mousePos.y - currentH / 2
            targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))
            targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

            let factor = perTick(wasMagnetHeld ? 0.85 : 0.92)
            let dx = (targetX - currentOrigin.x) * factor
            let dy = (targetY - currentOrigin.y) * factor
            setFrame(NSRect(x: currentOrigin.x + dx, y: currentOrigin.y + dy, width: currentW, height: currentH), display: sizeChanged)
            wasMagnetHeld = true
            return
        }

        wasMagnetHeld = false

        // Free-Flow Mode:
        // Horizontal: Default +22 to right; if the *badge* wouldn't fit, flip to the left of the pointer.
        // (Decided on the badge width, not the current width, so a growing notice doesn't flip mid-animation;
        // a wide notice near the edge is just pushed left by the clamp below.)
        if mousePos.x + 22 + badgeWidth > bounds.maxX - 6 {
            targetX = mousePos.x - currentW - 14
        } else {
            targetX = mousePos.x + 22
        }
        targetX = max(bounds.minX + 6, min(targetX, bounds.maxX - currentW - 6))

        // Vertical: Default -currentH - 10; if near bottom edge (or Dock), flip above (+14)
        if mousePos.y - currentH - 10 < bounds.minY + 6 {
            targetY = mousePos.y + 14
        } else {
            targetY = mousePos.y - currentH - 10
        }
        targetY = max(bounds.minY + 6, min(targetY, bounds.maxY - currentH - 6))

        if !isVisible {
            setFrame(NSRect(x: targetX, y: targetY, width: currentW, height: currentH), display: sizeChanged)
            orderFrontRegardless()
            return
        }

        // Fluid spring interpolation towards edge-aware target
        let dx = (targetX - currentOrigin.x) * perTick(0.35)
        let dy = (targetY - currentOrigin.y) * perTick(0.35)
        setFrame(NSRect(x: currentOrigin.x + dx, y: currentOrigin.y + dy, width: currentW, height: currentH), display: sizeChanged)
    }

    public func refreshHUD() {
        guard !isDragging, !isDismissing else { return }

        let count = queueManager.count
        let hasNewItems = count > previousCount
        previousCount = count

        hudView.updateCount(count, animateGlow: hasNewItems)

        if isActive { startTracking() } else { isTapSnapped = false; stopTracking() }   // the tick that resets it stops with the timer

        // Size changes animate in updatePosition(). When appearing for a notice, start as the dot and fade in,
        // so the message grows out of it from the left; otherwise appear at full size as before.
        if !isVisible {
            let startsAsDot = (notice != nil || isWorking) && queueManager.isEmpty
            setFrame(NSRect(origin: frame.origin, size: startsAsDot ? Self.dotSize : targetSize), display: false)
            if startsAsDot && !isSuspended {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { $0.duration = 0.12; self.animator().alphaValue = 1 }
            }
        }

        if isActive {
            if !isVisible && !previewPanel.isVisible && !isSuspended {
                let mousePos = NSEvent.mouseLocation
                setFrameOrigin(NSPoint(x: mousePos.x + 22, y: mousePos.y - frame.height - 10))
                orderFrontRegardless()
                // The full badge arrives with a short scale-and-fade instead of popping in (the dot case already fades above).
                if !(notice != nil || isWorking) || !queueManager.isEmpty { animateArrival() }
            }
        } else {
            orderOut(nil)
        }
    }

    private func animateArrival() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        alphaValue = 0
        if !reduceMotion, let layer = hudView.layer {
            let b = hudView.bounds
            var t = CATransform3DMakeTranslation(b.midX, b.midY, 0)   // a view's layer scales from its corner: pivot on the centre
            t = CATransform3DScale(t, 0.92, 0.92, 1)
            t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = t
            grow.toValue = CATransform3DIdentity
            grow.duration = 0.20
            grow.timingFunction = curve
            layer.add(grow, forKey: "arrive")
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.20
            context.timingFunction = curve
            self.animator().alphaValue = 1
        }
    }

    // MARK: - Notices

    /// Shows a message inside the pill. Replaces any notice already showing. The pill appears for it even
    /// when the deck is empty, grows to fit the text, and shrinks back when the notice ends.
    public func show(_ notice: PillNotice) {
        if isCollapsing {
            isCollapsing = false
            alphaValue = 1
        }
        self.notice = notice
        noticeToken &+= 1
        hudView.setNotice(notice)
        ProblemReport.record(notice)   // for "Report a Problem…" (memory only)

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: notice.spokenText,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )

        refreshHUD()
        if let duration = notice.duration { scheduleNoticeEnd(after: duration, token: noticeToken) }
    }

    /// Replaces the text of the notice that is showing (e.g. progress "3 of 12") without announcing it again
    /// or restarting its timer. Shows it normally if no notice is up.
    public func updateNotice(_ notice: PillNotice) {
        guard self.notice != nil else { show(notice); return }
        self.notice = notice
        hudView.setNotice(notice)
    }

    /// Ends the current notice (no-op if none is showing). With items in the deck the pill shrinks back to the
    /// count; on an empty deck it collapses back to its dot (right edge moving left) and fades out.
    public func dismissNotice(animated: Bool = true) {
        guard notice != nil else { return }
        notice = nil
        noticeToken &+= 1

        // Still working on an empty Que: shrink back to the bouncing dot instead of collapsing away.
        guard animated, queueManager.isEmpty, !isWorking, isVisible, !isSuspended else {
            hudView.setNotice(nil)
            if queueManager.isEmpty { hudView.restoreCountInstantly() }
            refreshHUD()
            return
        }
        hudView.setNotice(nil, restoringCount: false)
        isCollapsing = true
        let token = noticeToken
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Shrink first (updatePosition animates towards the dot), then fade the dot out.
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.14)) { [weak self] in
            guard let self = self, self.noticeToken == token else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; self.animator().alphaValue = 0 }, completionHandler: {
                guard self.noticeToken == token else { return }   // a new notice arrived mid-collapse
                self.isCollapsing = false
                self.orderOut(nil)
                self.alphaValue = 1
                self.hudView.restoreCountInstantly()
                self.refreshHUD()
            })
        }
    }

    private func scheduleNoticeEnd(after delay: TimeInterval, token: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.noticeToken == token else { return }
            // Don't pull the notice away while the user is holding ⌥ to catch the pill.
            if self.isCatching {
                self.scheduleNoticeEnd(after: 1.0, token: token)
                return
            }
            self.dismissNotice()
        }
    }

    // MARK: - DeckHUDViewDelegate

    public func deckHUDViewWillBeginDragging(_ view: DeckHUDView) {
        if previewPanel.isVisible {
            previewPanel.close()
        }
        isDragging = true
        setFrameOrigin(NSPoint(x: -500, y: -500))
    }

    public func deckHUDViewDidCompleteDrop(_ view: DeckHUDView) {
        isDragging = false
        isTapSnapped = false
        queueManager.clear()
    }

    public func deckHUDViewDidCancelDrop(_ view: DeckHUDView) {
        isDragging = false
        refreshHUD()
    }

    public func deckHUDViewDidRequestClear(_ view: DeckHUDView) {
        queueManager.clear()
        refreshHUD()
    }

    public func deckHUDViewDidRequestPreview(_ view: DeckHUDView) {
        togglePreview()
    }

    public func togglePreview() {
        if previewPanel.isVisible {
            previewPanel.close()
            return
        }
        guard !queueManager.isEmpty, !isDragging, !isDismissing else { return }

        // Morph effect: The pill seamlessly blossoms into the preview deck.
        // We hide the pill so there is NEVER a second deck beside it!
        let pillRect = self.frame
        self.alphaValue = 0.0

        previewPanel.open(from: pillRect, queueManager: queueManager) { [weak self] in
            guard let self = self else { return }
            self.isTapSnapped = false   // the preview did its job: ⌃⌃ mode lets go, like after a drop
            self.alphaValue = 1.0
            self.updatePosition()
        }
    }
}

