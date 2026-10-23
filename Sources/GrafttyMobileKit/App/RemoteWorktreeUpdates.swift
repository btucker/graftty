import GrafttyProtocol

/// One observation of a paired host's worktrees: an applied panes-state
/// frame, or the host's subscription failing or ending.
public enum RemoteWorktreeUpdate: Sendable, Equatable {
    case frame(PanesStateMessage)
    case unavailable
}

/// Bridges one host's worktree frames across panes-state channel lifetimes.
/// Each `WorktreePanesStore.frameUpdates()` stream ends with its channel;
/// this loop subscribes again: at once after a delivering channel that
/// stayed open for `minimumChannelLifetime`, after `retryDelay` when it
/// closed sooner, and after reporting the host unavailable and waiting when
/// no frame arrived. Observers see one stream while the host is reachable
/// and never poll. See
/// docs/superpowers/specs/2026-10-22-observable-worktree-store.md.
enum RemoteWorktreeUpdates {
    @MainActor static func stream(
        subscribe: @escaping @MainActor () async throws -> AsyncStream<PanesStateMessage>,
        retryDelay: @escaping @MainActor () async throws -> Void,
        minimumChannelLifetime: Duration = .seconds(5),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        bufferingPolicy: AsyncStream<RemoteWorktreeUpdate>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<RemoteWorktreeUpdate> {
        let (stream, continuation) = AsyncStream<RemoteWorktreeUpdate>.makeStream(
            bufferingPolicy: bufferingPolicy
        )
        let loop = Task { @MainActor in
            defer { continuation.finish() }
            while !Task.isCancelled {
                var deliveredFrame = false
                var opened: ContinuousClock.Instant?
                if let frames = try? await subscribe() {
                    opened = now()
                    for await frame in frames {
                        deliveredFrame = true
                        continuation.yield(.frame(frame))
                    }
                }
                guard !Task.isCancelled else { return }
                if deliveredFrame, let opened {
                    // A channel that stayed open was replaced or closed, so
                    // the next subscription usually succeeds at once. One that
                    // closed quickly waits first: a host whose channel opens
                    // and closes over and over must not be reopened at network
                    // speed. Either way it delivered, so the host is reachable.
                    if opened.duration(to: now()) >= minimumChannelLifetime { continue }
                } else {
                    continuation.yield(.unavailable)
                }
                do { try await retryDelay() } catch { return }
            }
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }
}
