import GrafttyHostAgent
import GrafttyProtocol

/// Host side of a `panes-state` channel subscription, shared by the V1 and
/// V2 subsystems.
///
/// Emits the initial snapshot before returning, so the first frame hits
/// the wire before the first sleep. It then re-reads the snapshot every
/// `interval` and re-emits only when it differs from the previously sent
/// one. Polling (rather than a pub-sub source) is intentional: AppState is
/// a SwiftUI `@State` value type with no Combine/AsyncStream publisher, and
/// the `/ws` HTTP path the desktop sidebar and web client use is itself
/// poll-based, so the SSH transport doesn't promise tighter freshness than
/// the HTTP transport already provides.
enum PanesStatePolling {
    static func subscribe(
        interval: Duration = .seconds(1),
        snapshot: @escaping @Sendable @MainActor () async -> PanesStateMessage,
        onChange: @escaping @Sendable (PanesStateMessage) async -> Void
    ) async -> PanesStateChannelHandler.Cancellable {
        let initial = await snapshot()
        await onChange(initial)

        let task = Task {
            var last = initial
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                let next = await snapshot()
                if next != last {
                    last = next
                    await onChange(next)
                }
            }
        }
        return PanesStateChannelHandler.Cancellable {
            task.cancel()
        }
    }
}
