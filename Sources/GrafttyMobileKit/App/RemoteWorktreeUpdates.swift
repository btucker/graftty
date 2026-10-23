import GrafttyProtocol

/// One observation of a paired host's worktrees: an applied panes-state
/// frame, or the host's subscription failing or ending.
public enum RemoteWorktreeUpdate: Sendable, Equatable {
    case frame(PanesStateMessage)
    case unavailable
}

/// Bridges one host's worktree frames across panes-state channel lifetimes.
/// Each `WorktreePanesStore.frameUpdates()` stream ends with its channel;
/// this loop subscribes again: at once after a delivering channel, after
/// `retryDelay` when one-frame channels repeat, and after reporting the
/// host unavailable and waiting when no frame arrived. Observers see one
/// stream while the host is reachable and never poll. See
/// docs/superpowers/specs/2026-10-22-observable-worktree-store.md.
enum RemoteWorktreeUpdates {
    @MainActor static func stream(
        subscribe: @escaping @MainActor () async throws -> AsyncStream<PanesStateMessage>,
        retryDelay: @escaping @MainActor () async throws -> Void
    ) -> AsyncStream<RemoteWorktreeUpdate> {
        let (stream, continuation) = AsyncStream<RemoteWorktreeUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let loop = Task { @MainActor in
            defer { continuation.finish() }
            // One immediate replacement per run of one-frame channels: a
            // host whose channel sends a frame and closes, over and over,
            // must not be reopened at network speed.
            var mayReplaceImmediately = true
            while !Task.isCancelled {
                var deliveredFrames = 0
                if let frames = try? await subscribe() {
                    for await frame in frames {
                        deliveredFrames += 1
                        continuation.yield(.frame(frame))
                    }
                }
                guard !Task.isCancelled else { return }
                // A second frame shows the channel lived past its replay.
                if deliveredFrames > 1 { mayReplaceImmediately = true }
                if deliveredFrames > 0, mayReplaceImmediately {
                    // A delivering channel was replaced or closed, so the
                    // next subscription usually succeeds at once.
                    mayReplaceImmediately = false
                    continue
                }
                // One that ended before any frame is a failure. A repeated
                // one-frame channel is still reachable, so it only waits.
                if deliveredFrames == 0 { continuation.yield(.unavailable) }
                do { try await retryDelay() } catch { return }
            }
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }
}
