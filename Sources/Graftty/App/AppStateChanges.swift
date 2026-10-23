import Combine
import Foundation
import GrafttyProtocol
import Observation

/// @spec PERF-1.16
/// When an observer subscribes to application state changes, the
/// application shall rebuild once immediately and then once per burst of
/// changes published while a rebuild is in progress, instead of rebuilding
/// on a fixed interval.
///
/// A revision counter for everything the sidebar and panes-state snapshots
/// read: `AppState` plus the stores those snapshots fold in (pane titles, PR
/// badges, stats, agent liveness, ports, remote Macs, project icons, default
/// branches). Consumers rebuild when it changes instead of on a timer. See
/// docs/superpowers/specs/2026-10-22-observable-worktree-store.md.
@MainActor
final class AppStateChanges {
    /// Bounds staleness from a change source nobody wired (PERF-1.17).
    nonisolated static let safetyNetInterval: Duration = .seconds(10)
    /// Lets a burst (a multi-step mutation) land before rebuilding.
    nonisolated static let settleInterval: Duration = .milliseconds(150)
    /// Keeps continuous changes (a sidebar or split drag, pane titles that
    /// animate while an agent works) from rebuilding more often than the
    /// 1 Hz poll this replaced (PERF-1.19).
    nonisolated static let minimumRebuildInterval: Duration = .seconds(1)

    /// The wait before a rebuild, given how long ago the previous one began.
    nonisolated static func settleDelay(sinceLastRebuild elapsed: Duration) -> Duration {
        max(settleInterval, minimumRebuildInterval - elapsed)
    }

    private let revisions = LatestValueBroadcast<UInt64>()
    private var revision: UInt64 = 0
    private var cancellables: Set<AnyCancellable> = []

    var currentRevision: UInt64 { revision }

    init() {
        revisions.publish(revision)
    }

    func publish() {
        revision &+= 1
        revisions.publish(revision)
    }

    /// Publishes after each value `publisher` emits.
    func publish<P: Publisher>(on publisher: P) where P.Failure == Never {
        publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.publish() } }
            .store(in: &cancellables)
    }

    /// Publishes whenever an `@Observable` property read by `track` changes.
    func publish(onChangeOf track: @escaping @MainActor () -> Void) {
        withObservationTracking(track) { [weak self] in
            // Tracking fires before the write lands and only once; publish
            // and re-arm after it.
            Task { @MainActor in
                guard let self else { return }
                self.publish()
                self.publish(onChangeOf: track)
            }
        }
    }

    /// Runs `refresh` for the latest revision, then again after `settle`
    /// whenever a newer revision is published or `ticks` fires. `settle`
    /// receives the time since the previous rebuild began. A rebuild
    /// already covering the latest revision is not repeated. Returns when
    /// the calling task is cancelled.
    nonisolated func observe(
        settle: @escaping @Sendable (_ sinceLastRebuild: Duration) async -> Void = {
            try? await Task.sleep(for: AppStateChanges.settleDelay(sinceLastRebuild: $0))
        },
        ticks: AsyncStream<Void> = AppStateChanges.ticks(every: AppStateChanges.safetyNetInterval),
        refresh: @escaping @MainActor () async -> Void
    ) async {
        // nil marks a safety-net tick, which always rebuilds.
        let (wakes, wake) = AsyncStream<UInt64?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let updates = revisions.updates()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await revision in updates { wake.yield(revision) }
            }
            group.addTask {
                for await _ in ticks { wake.yield(nil) }
            }
            let clock = ContinuousClock()
            // Read on the main actor as the rebuild starts, not before the hop:
            // a congested main actor could otherwise run a rebuild that already
            // covers a newer revision, or start it long after the recorded time.
            let rebuild: @MainActor () async -> (revision: UInt64?, start: ContinuousClock.Instant) = { [revisions] in
                let started = (revisions.latest, clock.now)
                await refresh()
                return started
            }
            var last: (revision: UInt64?, start: ContinuousClock.Instant)?
            for await woken in wakes {
                if woken != nil, let last, revisions.latest == last.revision { continue }
                if let last { await settle(clock.now - last.start) }
                guard !Task.isCancelled else { break }
                last = await rebuild()
            }
            group.cancelAll()
        }
    }

    /// A tick every `interval` until the observer stops iterating.
    nonisolated static func ticks(every interval: Duration) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                while (try? await Task.sleep(for: interval)) != nil { continuation.yield() }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
