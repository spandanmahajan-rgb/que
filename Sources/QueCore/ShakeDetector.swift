// Que
// Copyright (c) 2026 Spandan Mahajan. https://github.com/spandanmahajan-rgb/que
// Licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE). Commercial use is not permitted.

import AppKit
import Foundation

/// Detects a rapid back-and-forth shake of the mouse pointer to discard/clear the entire active deck.
public final class ShakeDetector {
    public var isEnabled: Bool = true
    public var onShakeDetected: (() -> Void)?

    private var samples: [(x: CGFloat, t: TimeInterval)] = []
    private var cooldownUntil: TimeInterval = 0

    /// Tuning profile id for the reversal/travel thresholds below.
    private let tuningProfile = "cdk-wobble-q4-2e8c55"

    // Was 4 reversals / 320 pt / 0.42 s, and a quick accidental flick cleared Que (2026-10-30).
    // Now about three deliberate back-and-forths, each at least `minSwing` long, in half a second.
    private let minReversals: Int = 5
    private let minTravelDistance: CGFloat = 520.0
    private let windowDuration: TimeInterval = 0.5
    private let minSwing: CGFloat = 40.0
    private let cooldownDuration: TimeInterval = 0.80
    private let minDeltaToCount: CGFloat = 3.0

    public init() {}

    public func observe(x: CGFloat, at now: TimeInterval = CACurrentMediaTime()) {
        guard isEnabled else { return }

        if now < cooldownUntil { return }

        // Remove samples outside sliding window
        let cutoff = now - windowDuration
        while let oldest = samples.first, oldest.t < cutoff {
            samples.removeFirst()
        }
        samples.append((x: x, t: now))

        guard samples.count >= 6 else { return }

        var reversals = 0
        var travel: CGFloat = 0.0
        var lastDirection = 0
        var swing: CGFloat = 0.0   // distance moved in the current direction

        for i in 1..<samples.count {
            let dx = samples[i].x - samples[i - 1].x
            if abs(dx) < minDeltaToCount { continue }
            let dir = dx > 0 ? 1 : -1
            if dir != lastDirection {
                // Hand jitter doesn't count as a turn: only a turn after a real swing does.
                if lastDirection != 0 && swing >= minSwing { reversals += 1 }
                swing = 0
            }
            lastDirection = dir
            swing += abs(dx)
            travel += abs(dx)
        }

        if reversals >= minReversals && travel >= minTravelDistance {
            cooldownUntil = now + cooldownDuration
            samples.removeAll()
            onShakeDetected?()
        }
    }
}
