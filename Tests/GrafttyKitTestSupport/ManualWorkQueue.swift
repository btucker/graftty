/// Retains submitted operations until a test runs a batch. Awaiting a batch
/// includes the operation's publication and slot release on MainActor.
@MainActor
public final class ManualWorkQueue {
    private var pending: [@MainActor @Sendable () async -> Void] = []

    public init() {}

    public var count: Int { pending.count }

    public func enqueue(_ work: @escaping @MainActor @Sendable () async -> Void) {
        pending.append(work)
    }

    public func runBatch() async {
        let batch = pending
        pending.removeAll()
        for work in batch { await work() }
    }
}
