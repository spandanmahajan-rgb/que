// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

public protocol DeckHUDViewDelegate: AnyObject {
    func deckHUDViewDidRequestClear(_ view: DeckHUDView)
    func deckHUDViewDidCompleteDrop(_ view: DeckHUDView)
    func deckHUDViewDidCancelDrop(_ view: DeckHUDView)
    func deckHUDViewWillBeginDragging(_ view: DeckHUDView)
    func deckHUDViewDidRequestPreview(_ view: DeckHUDView)
}

public final class DeckHUDView: NSView, NSDraggingSource {
    public weak var delegate: DeckHUDViewDelegate?

    /// Tint layered over the blur: near-black glass in dark mode, white glass in light mode (the pill follows the
    /// system appearance, 2.10.0). `isDarkLook` is set by `applyLook`.
    private static let darkTint = NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 0.55)
    private static let lightTint = NSColor(white: 1.0, alpha: 0.62)
    private var isDarkLook = true
    private var lookKey = ""   // light/dark + the two accessibility settings: applyLook re-runs when any of them changes
    private var tint: NSColor { Self.glassTint(dark: isDarkLook) }
    private var hairline: NSColor { Self.glassHairline(dark: isDarkLook) }
    /// Copy-glow peaks: a dark emerald on black glass; on white glass a pale mint, so the badge glows instead of blinking dark.
    private var glowFill: NSColor {
        isDarkLook ? NSColor(red: 0.12, green: 0.44, blue: 0.22, alpha: 0.88) : NSColor(red: 0.80, green: 0.97, blue: 0.86, alpha: 0.80)
    }
    private var glowRim: NSColor {
        isDarkLook ? NSColor(red: 0.30, green: 0.95, blue: 0.50, alpha: 0.95) : NSColor(red: 0.16, green: 0.68, blue: 0.34, alpha: 0.85)
    }
    /// Shared with the preview grid, which wears the same glass.
    static func glassTint(dark: Bool) -> NSColor {
        if solidGlass { return dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.96, alpha: 1) }
        return dark ? darkTint : lightTint
    }
    static func glassHairline(dark: Bool) -> NSColor {
        if strongEdges { return dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.50) }
        return dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)
    }
    /// Reduce transparency: glass becomes solid. Increase contrast: the edge becomes clearly visible.
    static var solidGlass: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
    static var strongEdges: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private var inkColor: NSColor { isDarkLook ? .white : NSColor(white: 0.08, alpha: 1) }
    /// Edge light: a crescent that sits on the side facing one fixed lamp above the screen (see `syncLight`).
    private let bevel = BevelView()
    public var queueManager: DeckQueueManager?

    // Native Liquid Glass Visual Effect View
    private let visualEffectView = NSVisualEffectView()

    // Subviews
    private let dotView = NSView()
    private let countLabel = NSTextField(labelWithString: "0")

    // Notice (PillNotice): text that replaces the count while a message is showing.
    // The text sits at its final width inside a clip that is exactly the pill's shape, so as the pill grows from the
    // left the text is revealed left-to-right (and hidden right-to-left as it shrinks) instead of popping in.
    private let noticeClipView = NSView()
    private let noticeStack = NSStackView()
    private var noticeWidthConstraint: NSLayoutConstraint?
    private let noticeMessageLabel = NSTextField(labelWithString: "")
    private let noticeDetailLabel = NSTextField(labelWithString: "")
    /// The notice currently shown, if any. Set through `setNotice(_:)`.
    public private(set) var activeNotice: PillNotice?

    private static let emerald = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0)
    /// Notice text stops growing the pill at this width and truncates instead.
    private static let noticeMaxTextWidth: CGFloat = 260
    private static let noticeLeading: CGFloat = 21      // dot (9 + 6) + 6pt gap
    private static let noticeTrailing: CGFloat = 12

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    private func setupView() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.cornerRadius = 14

        // 1. Native macOS Liquid Glass Material (Frosted Translucent Blur)
        // NOTE: .withinWindow instead of .behindWindow — .behindWindow requires a composited
        // window behind it to sample from. During app-switch animations macOS briefly has
        // no eligible window, causing the pill to go fully transparent (the "vanish" glitch).
        // .withinWindow always renders consistently regardless of what app is focused.
        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .withinWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 14
        visualEffectView.layer?.masksToBounds = true
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.frame = bounds
        addSubview(visualEffectView, positioned: .below, relativeTo: nil)
        bevel.frame = bounds
        bevel.autoresizingMask = [.width, .height]
        addSubview(bevel, positioned: .above, relativeTo: visualEffectView)

        // 2. Specular glass rim border and dark glass tint
        layer?.borderWidth = 1.0

        // 3. Ambient glass drop shadow matching exact capsule curve
        layer?.shadowRadius = 7

        // 4. Emerald active dot
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.0
        dotView.layer?.backgroundColor = NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
        dotView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dotView)

        // 5. High-legibility count typography
        countLabel.wantsLayer = true
        countLabel.isBezeled = false
        countLabel.drawsBackground = false
        countLabel.isEditable = false
        countLabel.isSelectable = false
        countLabel.textColor = .white   // applyLook sets the real colour
        countLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        // 6. Solid Deck Logo icon (subtle, secondary accent)

        NSLayoutConstraint.activate([
            // [ ● 3 ]: just the status dot and the count (the 10pt logo that used to follow was too small to read
            // and carried no information). With the badge widths in CursorHUDPanel (40pt + 8pt per extra digit) the
            // visible dot-to-digits group sits centred, ~10pt from each edge (the label box is wider than its digits).
            dotView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 6),
            dotView.heightAnchor.constraint(equalToConstant: 6),

            countLabel.leadingAnchor.constraint(equalTo: dotView.trailingAnchor, constant: 4),
            countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Not required: lets the pill shrink to its 28pt dot when collapsing (the count is hidden then).
            {
                let c = countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10)
                c.priority = .dragThatCannotResizeWindow   // < 500, so the window doesn't treat it as a minimum size
                return c
            }()
        ])

        // 7. Notice text (hidden until a PillNotice is shown)
        for label in [noticeMessageLabel, noticeDetailLabel] {
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            label.maximumNumberOfLines = 1
            label.cell?.truncatesLastVisibleLine = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        noticeMessageLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        noticeMessageLabel.textColor = .white   // applyLook
        noticeDetailLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        noticeDetailLabel.textColor = NSColor(white: 1.0, alpha: 0.72)   // applyLook
        noticeStack.orientation = .vertical
        noticeStack.alignment = .leading
        noticeStack.spacing = 1
        noticeStack.addArrangedSubview(noticeMessageLabel)
        noticeStack.addArrangedSubview(noticeDetailLabel)
        noticeClipView.wantsLayer = true
        noticeClipView.layer?.masksToBounds = true
        noticeClipView.autoresizingMask = [.width, .height]
        noticeClipView.frame = bounds
        addSubview(noticeClipView)

        noticeStack.translatesAutoresizingMaskIntoConstraints = false
        noticeStack.alphaValue = 0
        noticeClipView.addSubview(noticeStack)
        let width = noticeStack.widthAnchor.constraint(equalToConstant: 0)
        noticeWidthConstraint = width
        NSLayoutConstraint.activate([
            noticeStack.leadingAnchor.constraint(equalTo: noticeClipView.leadingAnchor, constant: Self.noticeLeading),
            noticeStack.centerYAnchor.constraint(equalTo: noticeClipView.centerYAnchor),
            width
        ])

        // VoiceOver: the pill is one button that announces how many items are in the deck.
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Que")
        setAccessibilityValue("0 items")
        setAccessibilityHelp("Press to copy everything in Que. \(QueControls.usesDoubleTap ? "Tap the Control key twice, then click" : "Hold the Option key and click") to see what's inside.")
        for subview in [dotView, countLabel, noticeClipView, noticeStack, noticeMessageLabel, noticeDetailLabel, bevel] {
            subview.setAccessibilityElement(false)
        }
        applyLook(animated: false)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in self?.applyLook(animated: true) }
    }

    // MARK: - Look and light

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyLook(animated: true)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        lastCenter = nil
        syncLight()
    }

    /// Black glass in dark mode, white glass in light mode, cross-faded over 0.25 s when the system switches.
    private func applyLook(animated: Bool) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != .aqua
        let key = "\(dark)\(Self.solidGlass)\(Self.strongEdges)"
        guard !animated || key != lookKey else { return }
        lookKey = key
        isDarkLook = dark
        if animated, let layer = layer {
            for key in ["backgroundColor", "borderColor"] {
                let fade = CABasicAnimation(keyPath: key)
                fade.fromValue = layer.presentation()?.value(forKeyPath: key) ?? layer.value(forKeyPath: key)
                fade.duration = 0.25
                layer.add(fade, forKey: "look-" + key)
            }
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.25
            bevel.layer?.add(transition, forKey: "lookFade")
            countLabel.layer?.add(transition, forKey: "lookFade")
        }
        layer?.backgroundColor = tint.cgColor
        layer?.borderColor = hairline.cgColor
        layer?.shadowColor = (dark ? NSColor.black : NSColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 1)).cgColor
        layer?.shadowOpacity = dark ? 0.45 : 0.30
        visualEffectView.material = dark ? .hudWindow : .popover
        visualEffectView.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        countLabel.textColor = inkColor
        noticeMessageLabel.textColor = inkColor
        noticeDetailLabel.textColor = inkColor.withAlphaComponent(dark ? 0.72 : 0.62)
        if activeNotice == nil { dotView.layer?.backgroundColor = idleDotColor.cgColor }
        bevel.isDark = dark
        bevel.needsDisplay = true
        syncLight()
    }

    private var lastCenter: CGPoint?
    private var travel = CGVector.zero      // smoothed movement per tick: the highlight lags behind it a little
    private var light = CGVector(dx: 0, dy: -1)

    /// Light mode only (dark mode keeps a still light): one fixed lamp hangs above the top-left of the screen the pill is on. The crescent sits on the side facing
    /// the lamp and the drop shadow falls away from it, so both change only because the pill moved (a function of
    /// position, no animation of their own); a small lean makes the highlight trail a moving pill, then settle.
    /// Called every tracking tick: when nothing changed it does almost nothing.
    public func syncLight() {
        guard let window = window else { return }
        // Dark mode: the light stays still (top-left and bottom-right edges), so moving the pill costs no redraw.
        if isDarkLook {
            setLight(Self.stillLight)
            lastCenter = nil
            return
        }
        let f = window.frame
        let center = CGPoint(x: f.midX, y: f.midY)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let last = lastCenter {
            let step = CGVector(dx: center.x - last.x, dy: center.y - last.y)
            travel = CGVector(dx: travel.dx * 0.75 + step.dx * 0.25, dy: travel.dy * 0.75 + step.dy * 0.25)
        }
        lastCenter = center
        let screen = (window.screen ?? NSScreen.main)?.frame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let lamp = CGPoint(x: screen.minX + screen.width * 0.2, y: screen.maxY + screen.height * 0.35)
        let d = max(hypot(center.x - lamp.x, center.y - lamp.y), 1)
        let lean: CGFloat = reduce ? 0 : 0.05
        let target = CGVector(dx: (center.x - lamp.x) / d - travel.dx * lean, dy: (center.y - lamp.y) / d - travel.dy * lean)
        let ease: CGFloat = reduce ? 1 : 0.3
        let next = CGVector(dx: light.dx + (target.dx - light.dx) * ease, dy: light.dy + (target.dy - light.dy) * ease)
        // Redraw only when the light has moved visibly (a redraw is a blurred CoreGraphics pass; doing it on every
        // 60 fps tick made moving the pill stutter).
        guard abs(next.dx - light.dx) > 0.03 || abs(next.dy - light.dy) > 0.03 else { return }
        setLight(CGVector(dx: max(-1.2, min(1.2, next.dx)), dy: max(-1.2, min(1.2, next.dy))))
    }

    private static let stillLight = CGVector(dx: 0.7, dy: -0.7)

    private func setLight(_ new: CGVector) {
        guard new != light else { return }
        light = new
        bevel.light = new
        bevel.needsDisplay = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowOffset = CGSize(width: new.dx * 3, height: new.dy * 3 - 2)
        CATransaction.commit()
    }

    /// VoiceOver "press" does what a plain click does: arms the clipboard with the whole deck.
    public override func accessibilityPerformPress() -> Bool {
        if let action = activeNotice?.primaryAction {
            action()
            return true
        }
        guard let items = queueManager?.items, !items.isEmpty else { return false }
        PasteboardWriter.shared.writeToPasteboard(items: items)
        showCopiedFeedback()
        return true
    }

    public override func layout() {
        super.layout()
        let radius = bounds.height / 2
        layer?.cornerRadius = radius
        visualEffectView.layer?.cornerRadius = radius
        visualEffectView.frame = bounds
        bevel.frame = bounds
        bevel.needsDisplay = true
        noticeClipView.frame = bounds
        noticeClipView.layer?.cornerRadius = radius
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        layoutShinePath()
    }

    /// Tracking paused: the dot turns orange (green while active). A notice still shows its own tone colour.
    public var isPaused = false {
        didSet {
            guard isPaused != oldValue else { return }
            if activeNotice == nil {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.duration = 0.2
                dotView.layer?.add(fade, forKey: "pauseFade")
                dotView.layer?.backgroundColor = idleDotColor.cgColor
                setAccessibilityValue(countDescription)
            }
        }
    }

    /// "Tap ⌃ twice" mode: snapped under the pointer. Any click is then a catch (click = preview, drag = drop), like ⌥
    /// is today. Cue: a ripple of green light flows out of the dot to the edges (no outline).
    public var isTapSnapped = false {
        didSet { if isTapSnapped != oldValue { updateShine() } }
    }

    /// The ripple: one soft ring, round like the dot (a circular radial gradient centred on the dot, as wide as the
    /// distance to the far end), growing out of the dot and fading. The capsule's edges cut it off as it spreads.
    /// `shineLayer` holds it and clips it to the capsule (the window is exactly the pill's size). It sits on the glass,
    /// under the dot and count. Reduce Motion: a steady soft glow around the dot. Keep `RimLight` (WelcomeWindow.swift)
    /// in step.
    private let shineLayer = CALayer()
    private let shineMask = CAShapeLayer()
    private let ripple = CAGradientLayer()
    private static let rippleSpread: CFTimeInterval = 3.6   // dot to edges
    private static let rippleCycle: CFTimeInterval = 5.4    // spread + rest

    private func updateShine() {
        guard let layer = layer else { return }
        if shineLayer.superlayer == nil {
            let green = Self.emerald
            ripple.type = .radial
            ripple.startPoint = CGPoint(x: 0.5, y: 0.5)
            ripple.endPoint = CGPoint(x: 1, y: 1)
            // A soft disc with a slightly brighter edge, clear at the rim.
            ripple.colors = [0.1, 0.12, 0.4, 0].map { green.withAlphaComponent($0).cgColor }
            ripple.locations = [0, 0.4, 0.8, 1]
            shineLayer.addSublayer(ripple)
            shineLayer.mask = shineMask
            layer.insertSublayer(shineLayer, above: visualEffectView.layer)
        }
        ripple.removeAllAnimations()
        shineLayer.removeAllAnimations()
        guard isTapSnapped else {
            fadeShine(to: 0)
            return
        }
        layoutShinePath()
        ripple.setAffineTransform(.identity)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            ripple.setAffineTransform(CGAffineTransform(scaleX: 0.45, y: 0.45))
            ripple.opacity = 1
        } else {
            // Both animations run the whole cycle (spread, then rest) so nothing falls back to resting values.
            let spread = Self.rippleSpread / Self.rippleCycle
            let grow = CAKeyframeAnimation(keyPath: "transform.scale")
            grow.values = [0.1, 1.2, 1.2]
            grow.keyTimes = [0, spread, 1] as [NSNumber]
            grow.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.25, 0.1, 0.35, 1),   // eases out like water
                                    CAMediaTimingFunction(name: .linear)]
            let glow = CAKeyframeAnimation(keyPath: "opacity")
            glow.values = [0, 1, 0, 0]
            glow.keyTimes = [0, spread * 0.25, spread, 1] as [NSNumber]
            glow.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn),
                                    CAMediaTimingFunction(name: .linear)]
            let group = CAAnimationGroup()
            group.animations = [grow, glow]
            group.duration = Self.rippleCycle
            group.repeatCount = .infinity
            ripple.opacity = 0
            ripple.add(group, forKey: "ripple")
        }
        fadeShine(to: 1)
    }

    private func fadeShine(to opacity: Float) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shineLayer.presentation()?.opacity ?? shineLayer.opacity
        fade.duration = 0.3
        shineLayer.opacity = opacity
        shineLayer.add(fade, forKey: "fade")
    }

    /// Follows the pill's size (notices grow it) without restarting the ripples.
    private func layoutShinePath() {
        guard shineLayer.superlayer != nil else { return }
        let radius = bounds.height / 2
        let dot = CGPoint(x: dotView.frame.midX, y: dotView.frame.midY)
        let reach = max(dot.x, bounds.width - dot.x)   // to the far end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shineLayer.frame = bounds
        shineMask.frame = bounds
        shineMask.path = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ripple.bounds = CGRect(x: 0, y: 0, width: reach * 2, height: reach * 2)   // bounds + position: frame is undefined under a scale
        ripple.position = dot
        CATransaction.commit()
    }

    private var idleDotColor: NSColor {
        if isWorking { return isDarkLook ? Self.workingGrey : Self.workingGreyOnLight }
        return isPaused ? .systemOrange : Self.emerald
    }

    private static let workingGrey = NSColor(white: 0.78, alpha: 1)
    private static let workingGreyOnLight = NSColor(white: 0.5, alpha: 1)

    /// Something is on its way into Que (a GIF being made, a pin downloading): grey dot, gently bouncing.
    /// With Reduce Motion it pulses in place instead. A notice still colours the dot while it shows.
    public var isWorking = false {
        didSet {
            guard isWorking != oldValue, let dot = dotView.layer else { return }
            if activeNotice == nil {
                let fade = CABasicAnimation(keyPath: "backgroundColor")
                fade.duration = 0.2
                dot.add(fade, forKey: "workFade")
                dot.backgroundColor = idleDotColor.cgColor
            }
            if isWorking {
                let motion: CAKeyframeAnimation
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    motion = CAKeyframeAnimation(keyPath: "opacity")
                    motion.values = [1.0, 0.35, 1.0]
                    motion.duration = 1.2
                } else {
                    motion = CAKeyframeAnimation(keyPath: "transform.translation.y")
                    motion.values = [0, 2.5, 0]          // a small hop (layer y points up in this view)
                    motion.keyTimes = [0, 0.4, 1]
                    motion.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
                    motion.duration = 0.55
                }
                motion.repeatCount = .infinity
                dot.add(motion, forKey: "working")
            } else {
                dot.removeAnimation(forKey: "working")
            }
            setAccessibilityValue(countDescription)
        }
    }

    private var countDescription: String {
        let count = queueManager?.count ?? 0
        let items = count == 1 ? "1 item" : "\(count) items"
        if isWorking { return "Adding to Que, \(items)" }
        return isPaused ? "Paused, \(items)" : items
    }

    public func updateCount(_ count: Int, animateGlow: Bool = false) {
        countLabel.stringValue = "\(count)"
        countLabel.isHidden = count == 0   // an empty Que that's working shows just the dot
        setAccessibilityValue(countDescription)
        needsDisplay = true

        // While a notice is showing (e.g. "Adding 3 of 48") it is the feedback; skip a glow per item.
        if animateGlow && count > 0 && activeNotice == nil {
            triggerCaptureGlowAnimation()
        }
    }

    // MARK: - Notices

    private static func textWidth(for notice: PillNotice) -> CGFloat {
        let font12 = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let font11 = NSFont.systemFont(ofSize: 11, weight: .regular)
        var width = (notice.message as NSString).size(withAttributes: [.font: font12]).width
        if let detail = notice.detail {
            width = max(width, (detail as NSString).size(withAttributes: [.font: font11]).width)
        }
        return min(ceil(width) + 2, noticeMaxTextWidth)
    }

    /// Size the pill needs to show `notice` (one line: 28pt tall, with a detail line: 42pt).
    public func preferredSize(for notice: PillNotice) -> NSSize {
        let width = Self.noticeLeading + Self.textWidth(for: notice) + Self.noticeTrailing
        return NSSize(width: max(width, 58), height: notice.detail == nil ? 28 : 42)
    }

    /// Shows `notice` in place of the count (or restores the count when `nil`). The panel animates the size;
    /// the text fades in while the growing pill reveals it from the left.
    public func setNotice(_ notice: PillNotice?, restoringCount: Bool = true) {
        let wasShowing = activeNotice != nil
        activeNotice = notice
        if let notice = notice {
            noticeMessageLabel.stringValue = notice.message
            noticeDetailLabel.stringValue = notice.detail ?? ""
            noticeDetailLabel.isHidden = notice.detail == nil
            noticeWidthConstraint?.constant = Self.textWidth(for: notice)
            dotView.layer?.backgroundColor = notice.tone.dotColor.cgColor
            setAccessibilityValue(notice.spokenText)
            guard !wasShowing else { return }   // text just changed (e.g. progress): no re-fade
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                countLabel.animator().alphaValue = 0
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                noticeStack.animator().alphaValue = 1
            }
        } else {
            dotView.layer?.backgroundColor = idleDotColor.cgColor
            setAccessibilityValue(countDescription)
            // Text fades while the shrinking pill hides it right-to-left; the count comes back once it's gone
            // (unless the pill is collapsing away entirely, when there is no count to show).
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                noticeStack.animator().alphaValue = 0
            }
            guard restoringCount else { return }
            // The count returns once the text has mostly cleared, then comes in quickly (an ease-in here felt laggy).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                guard let self = self, self.activeNotice == nil else { return }   // a new message took over meanwhile
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                    self.countLabel.animator().alphaValue = 1
                }
            }
        }
    }

    /// Puts the count back without animation (used after the pill collapsed away while showing a notice).
    public func restoreCountInstantly() {
        noticeStack.alphaValue = 0
        countLabel.alphaValue = 1
    }

    /// Solid shape illumination glow through native Liquid Glass
    public func triggerCaptureGlowAnimation() {
        guard let layer = self.layer else { return }

        // A copy during a glow continues it from what's on screen instead of snapping back to rest first.
        func live(_ target: CALayer, _ key: String, rest: CGColor) -> CGColor {
            guard target.animation(forKey: key) != nil, let p = target.presentation() else { return rest }
            return (key == "borderGlow" ? p.borderColor : p.backgroundColor) ?? rest
        }

        // 1. Solid Shape Background Glow: glass tint illuminates with rich emerald
        let bgGlow = CAKeyframeAnimation(keyPath: "backgroundColor")
        bgGlow.values = [
            live(layer, "bgGlow", rest: tint.cgColor),
            glowFill.cgColor,
            tint.cgColor
        ]
        bgGlow.keyTimes = [0.0, 0.30, 1.0]
        bgGlow.duration = 0.60
        bgGlow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(bgGlow, forKey: "bgGlow")

        // 2. Radiant Glass Rim Glow
        let borderGlow = CAKeyframeAnimation(keyPath: "borderColor")
        borderGlow.values = [
            live(layer, "borderGlow", rest: hairline.cgColor),
            glowRim.cgColor,
            hairline.cgColor
        ]
        borderGlow.keyTimes = [0.0, 0.30, 1.0]
        borderGlow.duration = 0.60
        borderGlow.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(borderGlow, forKey: "borderGlow")

        // 3. Dot Flash (not while a notice owns the dot colour)
        if activeNotice == nil, let dotLayer = dotView.layer {
            let dotAnim = CAKeyframeAnimation(keyPath: "backgroundColor")
            dotAnim.values = [
                live(dotLayer, "dotFlash", rest: NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor),
                NSColor(red: 0.65, green: 1.0, blue: 0.75, alpha: 1.0).cgColor,
                NSColor(red: 0.20, green: 0.85, blue: 0.40, alpha: 1.0).cgColor
            ]
            dotAnim.keyTimes = [0.0, 0.30, 1.0]
            dotAnim.duration = 0.60
            dotAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dotLayer.add(dotAnim, forKey: "dotFlash")
        }

        // 4. Count pop: a small, quick bump (skipped with Reduce Motion; the colour glow above still signals the capture)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let countLayer = countLabel.layer {
            let current = (countLayer.animation(forKey: "pop") != nil
                ? countLayer.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat : nil) ?? 1.0
            let popAnim = CAKeyframeAnimation(keyPath: "transform.scale")
            popAnim.values = [current, 1.08, 1.0]
            popAnim.keyTimes = [0.0, 0.3, 1.0]
            popAnim.duration = 0.30
            popAnim.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            countLayer.add(popAnim, forKey: "pop")
        }
    }

    /// Shake to clear: the badge shrinks slightly and fades out, then Que is cleared.
    public func triggerDismissPuffAnimation(completion: @escaping () -> Void) {
        let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        // Shrink a little around the centre while fading, so it reads as let go rather than switched off.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = layer {
            let c = CGPoint(x: bounds.midX, y: bounds.midY)   // a view's layer scales from its corner, so pivot on the centre
            var t = CATransform3DMakeTranslation(c.x, c.y, 0)
            t = CATransform3DScale(t, 0.9, 0.9, 1)
            t = CATransform3DTranslate(t, -c.x, -c.y, 0)
            let shrink = CABasicAnimation(keyPath: "transform")
            shrink.fromValue = CATransform3DIdentity
            shrink.toValue = t
            shrink.duration = 0.20
            shrink.timingFunction = curve
            shrink.fillMode = .forwards
            shrink.isRemovedOnCompletion = false
            layer.add(shrink, forKey: "dismissShrink")
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.20
            context.timingFunction = curve
            self.animator().alphaValue = 0.0
        }, completionHandler: {
            self.layer?.removeAnimation(forKey: "dismissShrink")
            self.alphaValue = 1.0
            completion()
        })
    }

    private var dragStartScreenPoint: NSPoint = .zero
    private var isDraggingSessionActive = false

    // MARK: - Drag & Drop and Click Handling

    private var clickHadOption = false
    private var clickHadShift = false

    /// True from a mouse-down on the pill until that click or drag ends (the panel holds still meanwhile).
    public private(set) var isPressed = false

    /// Press response: a tiny scale-down the moment the mouse goes down, eased back on release (an alpha dip with Reduce Motion).
    private func showPressed(_ down: Bool) {
        guard let layer = layer else { return }
        let curve = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
        let duration: CFTimeInterval = down ? 0.10 : 0.20
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = curve
                self.animator().alphaValue = down ? 0.85 : 1
            }
            return
        }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)   // pivot on the centre
        var pressed = CATransform3DMakeTranslation(c.x, c.y, 0)
        pressed = CATransform3DScale(pressed, 0.97, 0.97, 1)
        pressed = CATransform3DTranslate(pressed, -c.x, -c.y, 0)
        let anim = CABasicAnimation(keyPath: "transform")
        anim.fromValue = layer.presentation()?.transform ?? layer.transform
        anim.toValue = down ? pressed : CATransform3DIdentity
        anim.duration = duration
        anim.timingFunction = curve
        anim.fillMode = .forwards
        anim.isRemovedOnCompletion = !down   // hold the pressed state; the release settles back to the model value
        layer.add(anim, forKey: "press")
    }

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        showPressed(true)
        // A previous hold may still be settling; it belongs to that press, not this one.
        if longPress == .fired || longPress == .cancelled { longPress = .idle }
        if let notice = activeNotice, notice.hasActions {
            clickHadOption = event.modifierFlags.contains(.option) || isTapSnapped
            clickHadShift = event.modifierFlags.contains(.shift)
            dragStartScreenPoint = NSEvent.mouseLocation
            isDraggingSessionActive = false
            // Two choices (the board offer): holding the click picks the other one.
            if notice.primaryAction != nil && notice.alternateAction != nil { beginLongPress() }
            return
        }
        guard let items = queueManager?.items, !items.isEmpty else { return }
        dragStartScreenPoint = NSEvent.mouseLocation
        isDraggingSessionActive = false
        // Remember ⌥ at press time (user may release it before mouse-up)
        clickHadOption = event.modifierFlags.contains(.option) || isTapSnapped
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !isDraggingSessionActive else { return }

        let currentScreenPoint = NSEvent.mouseLocation
        let dist = hypot(currentScreenPoint.x - dragStartScreenPoint.x, currentScreenPoint.y - dragStartScreenPoint.y)

        // When ⌥ is held (the only way to catch the pill), allow a generous 20pt
        // threshold so trackpad clicks and resting fingers don't start an accidental drag.
        let isModifierHeld = event.modifierFlags.contains(.option) || isTapSnapped
            || CGEventSource.flagsState(.hidSystemState).contains(.maskAlternate)
        let threshold: CGFloat = isModifierHeld ? 20.0 : 4.0

        guard dist > threshold else { return }
        // Moving off turns a hold into a drag: no "add all".
        if longPress == .waiting || longPress == .shaking { longPress = .cancelled }
        guard let items = queueManager?.items, !items.isEmpty else { return }

        isDraggingSessionActive = true
        startDragSession(with: event, items: items)
    }

    public override func mouseUp(with event: NSEvent) {
        isPressed = false
        showPressed(false)
        // If a drag session was active, AppKit handles session end via draggingSession(_:endedAt:operation:)
        guard !isDraggingSessionActive else { return }

        let press = longPress
        if press == .waiting { longPress = .idle } else if press == .shaking { longPress = .cancelled }
        // A hold that was recognised (already ran "add all"), dragged away, or let go mid-shake is not a click.
        if press == .shaking || press == .fired || press == .cancelled {
            clickHadOption = false
            clickHadShift = false
            return
        }

        // A notice with actions (e.g. the board offer) answers the click instead of the deck: ⌥-click runs the
        // first choice, ⌥-click and hold the other (⌥⇧-click still works too; ⌥-click alone when there's just one).
        if let notice = activeNotice, notice.hasActions {
            let wantsAlternate = clickHadShift || notice.primaryAction == nil
            let action = wantsAlternate ? notice.alternateAction : notice.primaryAction
            clickHadOption = false
            clickHadShift = false
            action?()
            return
        }

        guard let items = queueManager?.items, !items.isEmpty else { return }

        // ⌥ + click (no drag) → toggle the preview grid instead of copying the batch
        if clickHadOption {
            clickHadOption = false
            delegate?.deckHUDViewDidRequestPreview(self)
            return
        }

        // Quick click without holding!
        // 1. Arm clipboard with full batch
        PasteboardWriter.shared.writeToPasteboard(items: items)

        // 2. Show green ✓ pop on pill
        showCopiedFeedback()
    }

    // MARK: - Click and hold: the alternate choice (adds a whole board)

    /// `waiting`: pressed, still a plain click. `shaking`: past the threshold, Que trembles while it gets ready.
    /// `fired`: the alternate ran (once). `cancelled`: let go early or dragged; the shake settles, nothing runs.
    enum LongPress { case idle, waiting, shaking, fired, cancelled }
    private var longPress: LongPress = .idle
    static let longPressShakeAfter: TimeInterval = 0.3
    static let longPressCommitAfter: TimeInterval = 0.8
    private var longPressTimer: Timer?
    private var longPressStart: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var shakeAmplitude: CGFloat = 0   // 0...1
    private var shakePhase: CGFloat = 0
    private var shakeOffset: CGFloat = 0      // points currently added to the window's x

    private func beginLongPress() {
        longPress = .waiting
        longPressStart = ProcessInfo.processInfo.systemUptime
        lastTick = longPressStart
        guard longPressTimer == nil else { return }   // still settling from a previous hold: keep its motion
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.longPressTick() }
        RunLoop.main.add(timer, forMode: .common)
        longPressTimer = timer
    }

    /// One clock drives both the gesture and the motion, so the shake can never outlive the hold.
    private func longPressTick() {
        let now = ProcessInfo.processInfo.systemUptime
        let held = now - longPressStart
        let dt = CGFloat(min(now - lastTick, 0.05))
        lastTick = now

        if longPress == .waiting && held >= Self.longPressShakeAfter { longPress = .shaking }
        if longPress == .shaking && held >= Self.longPressCommitAfter {
            longPress = .fired
            // The same notice check a click makes; a notice that changed under the finger runs nothing.
            if let notice = activeNotice, notice.primaryAction != nil { notice.alternateAction?() }
        }

        // Weighted: builds slowly while held, then slows and fades out once recognised or let go.
        if longPress == .shaking {
            shakeAmplitude += (1 - shakeAmplitude) * min(1, dt * 7)
        } else {
            shakeAmplitude *= pow(0.02, dt / 0.35)   // ~0.35 s to settle
        }
        shakePhase += 2 * .pi * (4 + 4 * shakeAmplitude) * dt   // 8 Hz at full, slowing to 4 Hz as it settles
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let settled = longPress != .waiting && longPress != .shaking && shakeAmplitude < 0.03
        let offset = (reduceMotion || settled) ? 0 : sin(shakePhase) * shakeAmplitude * 1.5
        // Side to side only: the window is exactly the pill's size, so a tilt would clip its corners. Applied as a
        // change, so it adds to wherever the panel puts Que and always ends exactly where it started.
        if let window = window, offset != shakeOffset {
            let base = window.frame.origin.x - shakeOffset
            window.setFrameOrigin(NSPoint(x: base + offset, y: window.frame.origin.y))
            shakeOffset = window.frame.origin.x - base   // macOS snaps windows to pixels: remember what really moved
        }

        if settled {
            longPressTimer?.invalidate()
            longPressTimer = nil
            shakeAmplitude = 0   // `fired`/`cancelled` stay until the next press, so its mouse-up is still swallowed
        }
    }

    private func startDragSession(with event: NSEvent, items: [DeckItem]) {
        // 1. Arm system clipboard with full batch payload
        PasteboardWriter.shared.writeToPasteboard(items: items)

        // 2. Build one NSDraggingItem per queued image using native NSURL.
        // NSURL natively provides:
        //   • public.file-url
        //   • CorePasteboardFlavorType 0x6675726C
        //   • NSFilenamesPboardType
        //   • Apple URL pasteboard type
        let draggingItems: [NSDraggingItem] = items.enumerated().map { idx, item in
            let dragItem = NSDraggingItem(pasteboardWriter: item.fileURL as NSURL)

            // Use the actual image as the drag thumbnail (64pt square, stacked)
            let thumbSize: CGFloat = 64
            // AUDIT: use the cached downsampled thumbnail instead of decoding every full-size image
            // synchronously on the main thread when the drag starts.
            let thumb: NSImage = DeckThumbnailCache.shared.thumbnail(for: item.fileURL)
                ?? NSImage(contentsOf: item.fileURL)
                ?? NSWorkspace.shared.icon(forFile: item.fileURL.path)
            // Slight offset per item so the stack is visible
            let offset = CGFloat(idx) * 4
            dragItem.setDraggingFrame(
                NSRect(x: offset, y: -offset, width: thumbSize, height: thumbSize),
                contents: thumb
            )
            return dragItem
        }

        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack

        // 3. Register global NSFilenamesPboardType paths array on dragging pasteboard (critical for WhatsApp/Catalyst)
        let paths = items.map { $0.fileURL.path }
        session.draggingPasteboard.setPropertyList(paths, forType: .init("NSFilenamesPboardType"))

        // Park badge off-screen so it doesn't block the drag target
        delegate?.deckHUDViewWillBeginDragging(self)
    }

    // MARK: - NSDraggingSource

    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Strictly return .copy so target apps (Google Slides, Chrome, Figma, WhatsApp) never attempt a .move.
        // ⌥ still held at the drop means "copy" to macOS, so ⌥ + drag + drop completes without letting go of ⌥
        // (owner-tested in Slides and WhatsApp). ⌘ held at the drop would mean "move" and be refused.
        return .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDraggingSessionActive = false
        isPressed = false
        showPressed(false)
        if operation != [] {
            delegate?.deckHUDViewDidCompleteDrop(self)
        } else {
            delegate?.deckHUDViewDidCancelDrop(self)
        }
    }

    /// Shows instant feedback on the pill when clicked to copy
    private var copiedFeedbackToken = 0

    public func showCopiedFeedback() {
        triggerCaptureGlowAnimation()
        // AUDIT: the old version remembered the *displayed* text and restored it later. Clicking twice
        // within 1.2s remembered "✓" itself and left the pill stuck on ✓; a copy during the 1.2s restored a
        // stale count. Restore the live count instead, and let only the latest click's timer act.
        copiedFeedbackToken &+= 1
        let token = copiedFeedbackToken
        countLabel.stringValue = "✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, self.copiedFeedbackToken == token else { return }
            self.countLabel.stringValue = "\(self.queueManager?.count ?? 0)"
        }
    }

}


/// The edge light, drawn as inset shadows clipped to the capsule: a bright crescent on the side that faces the lamp
/// (thick in the middle, tapering to points), a dimmer one opposite, and a soft inner glow so the surface rounds over.
/// `light` points from the lamp to the pill (screen coordinates, y up). Also rims the preview grid, with a corner
/// radius instead of a capsule and a weaker light in dark mode.
final class BevelView: NSView {
    var light = CGVector(dx: 0, dy: -1)
    var isDark = true
    var cornerRadius: CGFloat?      // nil = capsule
    var strength: CGFloat = 1       // scales every highlight's opacity

    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, bounds.height > 1 else { return }
        let r = bounds
        let radius = min(cornerRadius ?? r.height / 2, r.height / 2)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        let lx = light.dx, ly = light.dy
        func inset(_ k: CGFloat, blur: CGFloat, grow: CGFloat, _ color: NSColor) {
            let hole = CGPath(roundedRect: r.insetBy(dx: -grow, dy: -grow), cornerWidth: radius + grow, cornerHeight: radius + grow, transform: nil)
            let path = CGMutablePath()
            path.addRect(r.insetBy(dx: -80, dy: -80))
            path.addPath(hole)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: lx * k, height: ly * k), blur: blur,
                          color: color.withAlphaComponent(color.alphaComponent * strength).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        inset(0.7, blur: 5, grow: 2.1, NSColor(white: 1, alpha: isDark ? 0.26 : 0.9))
        inset(-2.2, blur: isDark ? 2.1 : 2.8, grow: isDark ? 1.75 : 1.4,
              isDark ? NSColor(white: 1, alpha: 0.5) : NSColor(red: 0.08, green: 0.08, blue: 0.16, alpha: 0.22))
        inset(2.5, blur: 1.75, grow: 1.4, NSColor(white: 1, alpha: isDark ? 0.95 : 1))
    }
}
