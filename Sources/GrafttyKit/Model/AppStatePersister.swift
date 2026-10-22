import Foundation

/// @spec PERSIST-2.3
/// When `AppState` changes, the application shall coalesce the changes into
/// one `state.json` write that runs off the main thread no later than the
/// save delay after the first unsaved change.
///
/// Single owner of `state.json` writes for the app. Callers hand it the
/// current state on every mutation; the first unsaved mark arms a trailing
/// timer and later marks only replace the pending snapshot, so a steady
/// stream of mutations still saves once per delay instead of starving.
///
/// Every write (timer, `flushNow`, termination) goes through one serial
/// queue, so snapshots reach disk in the order they were taken and an older
/// snapshot can never land after a newer one (PERSIST-2.4). A dedicated
/// queue rather than `OffMainIO`: that queue serializes team-inbox work that
/// can block on an inter-process lock, which would delay saves behind it.
@MainActor
public final class AppStatePersister {
    public typealias Write = @Sendable (AppState) throws -> Void
    /// Runs `action` on the main actor after `delay`; returns a cancel handle.
    public typealias Schedule = @MainActor @Sendable (
        _ delay: Duration,
        _ action: @escaping @MainActor () -> Void
    ) -> @MainActor () -> Void

    public nonisolated static let defaultDelay: Duration = .milliseconds(300)

    private let delay: Duration
    private let write: Write
    private let schedule: Schedule
    private let queue = DispatchQueue(label: "com.graftty.app-state-persister", qos: .utility)
    private let failedWrite = FailedWrite()
    private var pending: AppState?
    /// Last snapshot handed to the queue. Skips the redundant write when a
    /// window's `.onChange` re-marks a state a caller already flushed; if that
    /// write failed, the skipping pass retries it from `failedWrite`.
    private var lastEnqueued: AppState?
    private var cancelTimer: (@MainActor () -> Void)?

    /// @spec PERSIST-2.8
    /// When `AppState` is marked for saving, the application shall notify the
    /// registered change observer on every mark, whether or not a window is
    /// open.
    ///
    /// Called on every `markDirty`, with or without a window, so it is a
    /// window-independent change signal for paths that mark the persister.
    public var onMarkDirty: (@MainActor () -> Void)?

    public convenience init(directory: URL, delay: Duration = AppStatePersister.defaultDelay) {
        self.init(delay: delay, write: { try $0.save(to: directory) })
    }

    public init(
        delay: Duration = AppStatePersister.defaultDelay,
        write: @escaping Write,
        schedule: @escaping Schedule = AppStatePersister.taskSchedule
    ) {
        self.delay = delay
        self.write = write
        self.schedule = schedule
    }

    public nonisolated static let taskSchedule: Schedule = { delay, action in
        let task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    /// Record `state` as the newest unsaved snapshot.
    public func markDirty(_ state: AppState) {
        pending = state
        onMarkDirty?()
        guard cancelTimer == nil else { return }
        cancelTimer = schedule(delay) { [weak self] in
            guard let self else { return }
            self.cancelTimer = nil
            let state = self.takePending()
            self.queue.async { [write, failedWrite] in
                try? Self.perform(state, write: write, failedWrite: failedWrite)
            }
        }
    }

    /// @spec PERSIST-2.5
    /// When a request launches an agent whose CLI hooks read `state.json`,
    /// the application shall write every marked state change to disk before
    /// replying.
    ///
    /// Writes the newest marked snapshot now, after any write already in
    /// flight, and returns once it is on disk. With nothing new pending it
    /// still waits for the in-flight write and retries it if it failed, so a
    /// successful return always means the newest marked state is on disk.
    public func flushNow() async throws {
        let state = takePendingCancellingTimer()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [write, failedWrite] in
                continuation.resume(with: Result { try Self.perform(state, write: write, failedWrite: failedWrite) })
            }
        }
    }

    /// @spec PERSIST-2.6
    /// When the application terminates, it shall synchronously write the
    /// newest state after any in-flight write completes, so quitting never
    /// loses the last change.
    ///
    /// Blocks the caller. Reserved for `applicationWillTerminate` and the
    /// rare request paths that must not suspend before replying.
    public func flushSynchronously() throws {
        let state = takePendingCancellingTimer()
        try queue.sync { [write, failedWrite] in
            try Self.perform(state, write: write, failedWrite: failedWrite)
        }
    }

    private func takePendingCancellingTimer() -> AppState? {
        cancelTimer?()
        cancelTimer = nil
        return takePending()
    }

    private func takePending() -> AppState? {
        guard let state = pending else { return nil }
        pending = nil
        guard state != lastEnqueued else { return nil }
        lastEnqueued = state
        return state
    }

    /// Runs on `queue`. Writes `state`, or, when a pass has no newer
    /// snapshot, retries the last failed one. The failed snapshot is always
    /// the newest one attempted, so a retry can never land an older state.
    private nonisolated static func perform(
        _ state: AppState?,
        write: Write,
        failedWrite: FailedWrite
    ) throws {
        guard let target = state ?? failedWrite.state else { return }
        do {
            try write(target)
            failedWrite.state = nil
        } catch {
            failedWrite.state = target
            // A full disk, read-only `$HOME` or permissions clash would
            // otherwise silently stop persistence. STATE-6.2 / PERSIST-2.2.
            NSLog("[Graftty] AppState.save failed: %@", String(describing: error))
            throw error
        }
    }
}

/// The newest snapshot whose write failed. Confined to the persister queue.
private final class FailedWrite: @unchecked Sendable {
    var state: AppState?
}
