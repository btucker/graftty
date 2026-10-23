import GrafttyHostAgent
import GrafttyProtocol

extension AppStateChanges {
    /// Host side of a `panes-state` channel subscription, shared by the V1
    /// and V2 subsystems (PERF-1.21).
    ///
    /// The first rebuild `observe` runs is the initial snapshot, and this
    /// waits for it to be sent, so the first frame hits the wire before the
    /// subscription returns. Later rebuilds (on a published change or the
    /// safety-net tick) are sent only when they differ from the last one
    /// sent.
    nonisolated func subscribePanesState(
        settle: @escaping @Sendable (_ sinceLastRebuild: Duration) async -> Void = AppStateChanges.waitToSettle,
        ticks: AsyncStream<Void> = AppStateChanges.ticks(every: AppStateChanges.safetyNetInterval),
        snapshot: @escaping @Sendable @MainActor () async -> PanesStateMessage,
        onChange: @escaping @Sendable (PanesStateMessage) async -> Void
    ) async -> PanesStateChannelHandler.Cancellable {
        let (initialSent, sentInitial) = AsyncStream<Void>.makeStream()
        let task = Task {
            var last: PanesStateMessage?
            await observe(settle: settle, ticks: ticks) {
                let next = await snapshot()
                if next != last {
                    last = next
                    await onChange(next)
                }
                sentInitial.finish()
            }
            sentInitial.finish()
        }
        for await _ in initialSent {}
        return PanesStateChannelHandler.Cancellable {
            task.cancel()
        }
    }
}
