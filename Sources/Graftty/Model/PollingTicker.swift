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
                // Re-check cancellation after the actor hop — without
                // this, a cancel arriving during the `paused` lookup
                // would still produce one more tick before the loop
                // exits (CR-6).
                if !isPaused && !Task.isCancelled {
                    await onTick()
                }
                await heart.sleepUntilPulseOrInterval(for: interval)
            }
        }
    }

    func stop() {
        // `task?.cancel()` now wakes the heart's in-flight sleep
        // directly via the cancellation handler installed in
        // `sleepUntilPulseOrInterval`, so the loop returns promptly
        // instead of waiting up to a full interval.
        task?.cancel()
        task = nil
        // Defensive belt-and-suspenders pulse: also kept as a
        // deterministic wake path in case the cancellation handler
        // races with the continuation install. Cheap, and the heart
        // tolerates a redundant pulse.
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
///
/// The timer uses `DispatchQueue.asyncAfter` rather than
/// `Task.sleep` deliberately. Under heavy parallel test contention
/// on macos-26 CI (170+ parallel test suites), the Swift Concurrency
/// global executor can starve detached tasks for seconds — so a
/// `Task.detached { try? await Task.sleep(...) }` paired with
/// `await s.value` could take many seconds longer than the requested
/// interval. GCD timers fire on libdispatch's own timer infrastructure,
/// which is unaffected by the Swift Concurrency executor's saturation.
/// We still hop to the actor's executor at fire time to resume the
/// continuation, but the *timing* of when the fire occurs is no
/// longer subject to global-executor pressure.
///
/// `generation` is a monotonic token bumped on every `sleepUntilPulseOrInterval`
/// call and on every `pulse()`. A stale fire (i.e., a timer scheduled
/// for an earlier sleep, arriving after a pulse already resumed our
/// continuation and the loop moved on) is filtered out by comparing
/// the captured generation at schedule-time against the current one.
private actor PollingHeart {
    private var pulsePending = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var generation: Int = 0

    func pulse() {
        pulsePending = true
        generation &+= 1
        if let c = continuation {
            continuation = nil
            c.resume()
        }
    }

    func sleepUntilPulseOrInterval(for interval: Duration) async {
        if pulsePending {
            pulsePending = false
            return
        }
        generation &+= 1
        let myGeneration = generation
        let nanos = interval.components.seconds * 1_000_000_000
            + interval.components.attoseconds / 1_000_000_000

        // `withTaskCancellationHandler` wraps the continuation so a
        // cancel arriving on the outer Task wakes the sleep directly
        // via `cancellationFired()`. Without this, `withCheckedContinuation`
        // is unresponsive to cancellation and `stop()` would only halt
        // the loop when the GCD timer (or the defensive pulse) fired —
        // up to a full interval later under executor pressure.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                // If cancellation arrived between the actor hop into
                // this method and now, resume immediately rather than
                // parking. The `onCancel` handler may have already run
                // and found `continuation == nil`, so we must check
                // here too.
                if Task.isCancelled {
                    c.resume()
                    return
                }
                self.continuation = c
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .nanoseconds(Int(nanos))
                ) { [weak self] in
                    Task { [weak self] in
                        await self?.timerFired(generation: myGeneration)
                    }
                }
            }
            // Either pulse resumed us, the timer did, or cancellation
            // did. In all cases the pulse signal (if any) has been
            // consumed by this iteration; the next call starts fresh.
            pulsePending = false
        } onCancel: {
            // `onCancel` runs synchronously on the cancelling executor,
            // not on this actor's executor — hop back to safely touch
            // the continuation.
            Task { [weak self] in
                await self?.cancellationFired()
            }
        }
    }

    private func cancellationFired() {
        // Cancel may arrive before, during, or after the continuation
        // is installed. If installed, resume it; otherwise the
        // pre-install `Task.isCancelled` check inside the continuation
        // closure handles it.
        if let c = continuation {
            continuation = nil
            c.resume()
        }
    }

    private func timerFired(generation: Int) {
        // Reject stale timers from prior generations (a pulse may
        // have already woken us, or `stop()` may have torn the loop
        // down).
        guard generation == self.generation else { return }
        if let c = continuation {
            continuation = nil
            c.resume()
        }
    }
}
