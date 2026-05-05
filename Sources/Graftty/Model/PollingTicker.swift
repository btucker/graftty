import Foundation
import AppKit
import GrafttyKit

/// Drives a single long-lived Task that fires `onTick` on a cadence.
/// Reacts to app active/inactive notifications (optionally pausing
/// when inactive), and exposes `pulse()` to wake early for
/// user-triggered refreshes.
///
/// The sleep lives inside `PollingHeart`, a private actor with its
/// own serial executor. This is load-bearing: keeping the sleep on
/// `@MainActor` made `Task.sleep` block waiting for MainActor cycles
/// under contention (Swift 6.2's "approachable concurrency" defaults
/// a lot of code to MainActor), so a 40ms interval would stretch to
/// hundreds of ms. Routing through `PollingHeart` decouples cadence
/// from MainActor pressure. Only the brief `onTick()` invocation hops
/// to MainActor.
/// @spec PR-8.10
@MainActor
final class PollingTicker: PollingTickerLike {
    private let interval: Duration
    private let pauseWhenInactive: @MainActor () -> Bool
    private let heart = PollingHeart()
    private var task: Task<Void, Never>?
    private var paused = false
    private var activeObserver: NSObjectProtocol?
    private var inactiveObserver: NSObjectProtocol?

    init(
        interval: Duration,
        pauseWhenInactive: @MainActor @escaping () -> Bool = { true }
    ) {
        self.interval = interval
        self.pauseWhenInactive = pauseWhenInactive
    }

    func start(onTick: @MainActor @escaping () async -> Void) {
        guard task == nil else { return }
        installObservers()
        let interval = self.interval
        let heart = self.heart
        task = Task.detached { [weak self] in
            while !Task.isCancelled {
                let isPaused = await self?.paused ?? true
                if !isPaused {
                    await onTick()
                }
                await heart.sleepUntilPulseOrInterval(for: interval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        // Wake the heart's in-flight sleep so the cancelled polling
        // loop can return promptly instead of waiting up to a full
        // interval.
        let heart = self.heart
        Task.detached { await heart.pulse() }
        removeObservers()
    }

    func pulse() {
        let heart = self.heart
        Task.detached { await heart.pulse() }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        activeObserver = center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.paused = false }
        }
        inactiveObserver = center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.pauseWhenInactive() {
                    self.paused = true
                }
            }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let o = activeObserver { center.removeObserver(o); activeObserver = nil }
        if let o = inactiveObserver { center.removeObserver(o); inactiveObserver = nil }
    }
}

/// Owns the polling cadence on its own actor executor — independent
/// of MainActor contention. `pulse()` cancels the current sleep so
/// the next tick fires immediately; if `pulse()` arrives between
/// sleeps, the `pulsePending` flag makes the next sleep return
/// without waiting.
private actor PollingHeart {
    private var sleepTask: Task<Void, Never>?
    private var pulsePending = false

    func pulse() {
        pulsePending = true
        sleepTask?.cancel()
    }

    func sleepUntilPulseOrInterval(for interval: Duration) async {
        if pulsePending {
            pulsePending = false
            return
        }
        let s = Task.detached { [interval] in
            _ = try? await Task.sleep(for: interval)
        }
        sleepTask = s
        _ = await s.value
        sleepTask = nil
        // Either the sleep completed naturally or `pulse()` cancelled
        // it; in both cases consume the flag so the next sleep doesn't
        // also short-circuit.
        pulsePending = false
    }
}
