import Foundation
import GrafttyHostAgent
import GrafttyProtocol

/// One producer per projection (local V1 or relayed V2), with independent,
/// bounded delivery to each viewer. A slow write cannot delay its siblings.
@MainActor
final class SharedPanesStateFeed {
    private let changes: AppStateChanges
    private let settle: @Sendable (Duration) async -> Void
    private let ticks: @Sendable () -> AsyncStream<Void>
    private let snapshot: @Sendable @MainActor () async -> PanesStateMessage
    private var observer: Task<Void, Never>?
    private var generation = UUID()
    private var latest: PanesStatePublication?
    private var subscribers: [UUID: AsyncStream<PanesStatePublication>.Continuation] = [:]

    init(changes: AppStateChanges,
         settle: @escaping @Sendable (Duration) async -> Void = AppStateChanges.waitToSettle,
         ticks: @escaping @Sendable () -> AsyncStream<Void> = { AppStateChanges.ticks(every: AppStateChanges.safetyNetInterval) },
         snapshot: @escaping @Sendable @MainActor () async -> PanesStateMessage) {
        self.changes = changes
        self.settle = settle
        self.ticks = ticks
        self.snapshot = snapshot
    }

    func subscribe(_ onChange: @escaping @Sendable (PanesStatePublication) async -> Void) async -> PanesStateChannelHandler.Cancellable {
        let id = UUID()
        let (updates, update) = AsyncStream<PanesStatePublication>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (initial, sentInitial) = AsyncStream<Void>.makeStream()
        subscribers[id] = update
        if let latest { update.yield(latest) }
        let delivery = Task {
            defer { sentInitial.finish() }
            for await publication in updates {
                guard !Task.isCancelled else { return }
                await onChange(publication)
                sentInitial.finish()
            }
        }
        if observer == nil {
            let generation = self.generation
            observer = Task { [weak self, changes, settle, ticks, snapshot] in
                await changes.observe(settle: settle, ticks: ticks()) { [weak self] in
                    let message = await snapshot()
                    guard let self, self.generation == generation, self.latest?.message != message else { return }
                    // Encoding a large sidebar must not monopolize the UI actor.
                    let publication = await Task.detached { PanesStatePublication(message) }.value
                    guard !Task.isCancelled, self.generation == generation else { return }
                    self.latest = publication
                    for subscriber in self.subscribers.values { subscriber.yield(publication) }
                }
            }
        }
        let cancellation = PanesStateChannelHandler.Cancellable { [weak self] in
            update.finish()
            delivery.cancel()
            Task { @MainActor in self?.removeSubscriber(id) }
        }
        for await _ in initial {}
        if Task.isCancelled { cancellation.cancel() }
        return cancellation
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
        guard subscribers.isEmpty else { return }
        generation = UUID()
        observer?.cancel()
        observer = nil
        latest = nil
    }

    deinit { observer?.cancel() }
}
