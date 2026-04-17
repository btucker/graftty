import Foundation
import AppKit
import EspalierKit

/// Drives a single long-lived Task that fires `onTick` on a cadence.
/// Reacts to app active/inactive notifications (optionally pausing when
/// inactive), and exposes `pulse()` to wake early for user-triggered
/// refreshes.
@MainActor
final class PollingTicker: PollingTickerLike {
    private let interval: Duration
    private let pauseWhenInactive: @MainActor () -> Bool
    private var task: Task<Void, Never>?
    private var pulseContinuation: AsyncStream<Void>.Continuation?
    private var pulseStream: AsyncStream<Void>?
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
        let (stream, cont) = AsyncStream<Void>.makeStream()
        pulseStream = stream
        pulseContinuation = cont

        installObservers()

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.paused {
                    await onTick()
                }
                await self.sleepOrPulse()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        pulseContinuation?.finish()
        pulseContinuation = nil
        pulseStream = nil
        removeObservers()
    }

    func pulse() {
        pulseContinuation?.yield(())
    }

    // MARK: - Private

    private func sleepOrPulse() async {
        let sleepTask = Task<Void, Never> { [interval] in
            try? await Task.sleep(for: interval)
        }
        let pulseTask: Task<Void, Never>
        if let pulseStream {
            pulseTask = Task {
                for await _ in pulseStream {
                    return
                }
            }
        } else {
            pulseTask = Task {}
        }
        // Await whichever finishes first.
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sleepTask.value }
            group.addTask { await pulseTask.value }
            await group.next()
            group.cancelAll()
        }
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
