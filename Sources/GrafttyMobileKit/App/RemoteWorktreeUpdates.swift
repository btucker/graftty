import GrafttyProtocol

/// One observation of a paired host's worktrees: an applied panes-state
/// frame, or the host's subscription failing or ending.
public enum RemoteWorktreeUpdate: Sendable, Equatable {
    case frame(PanesStateMessage)
    case unavailable
}

/// Bridges one host's worktree frames across panes-state channel lifetimes.
/// Each `WorktreePanesStore.frameUpdates()` stream ends with its channel; this loop
/// reports the gap, waits `retryDelay`, and subscribes again, so observers
/// see one stream while the host is reachable and never poll. See
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
            while !Task.isCancelled {
                if let frames = try? await subscribe() {
                    for await frame in frames {
                        continuation.yield(.frame(frame))
                    }
                }
                guard !Task.isCancelled else { return }
                continuation.yield(.unavailable)
                do { try await retryDelay() } catch { return }
            }
        }
        continuation.onTermination = { _ in loop.cancel() }
        return stream
    }
}
