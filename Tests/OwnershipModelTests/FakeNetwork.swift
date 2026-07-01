import GrafttyProtocol

/// Simulates a network layer for the ownership-model harness.
///
/// Holds per-connection ordered out-queues.  Within one connection, deliveries
/// are FIFO (mirroring TCP reality); across connections the scheduler may
/// interleave freely.
struct FakeNetwork {
    /// Per-connection ordered delivery queues.
    /// Key: arbitrary integer connection ID.
    /// Value: ordered list of pending deliveries (head = next to deliver).
    private var queues: [Int: [Delivery]] = [:]

    /// Monotonically increasing per-connection ordinal counters.
    /// `connectionSeq` on each `Delivery` reflects the 0-based send order
    /// within that connection, not the connection identifier itself.
    private var nextSeq: [Int: Int] = [:]

    /// Enqueue a snapshot delivery on the given connection.
    mutating func enqueue(target: DisplayClientID, snapshot: DisplayOwnershipSnapshot, connection: Int, emissionSeq: UInt64) {
        let seq = nextSeq[connection, default: 0]
        nextSeq[connection] = seq + 1
        queues[connection, default: []].append(
            Delivery(target: target, snapshot: snapshot, connectionSeq: seq, emissionSeq: emissionSeq)
        )
    }

    /// Pop the next delivery for a specific connection (FIFO within that connection).
    @discardableResult
    mutating func dequeue(connection: Int) -> Delivery? {
        guard var queue = queues[connection], !queue.isEmpty else { return nil }
        let delivery = queue.removeFirst()
        queues[connection] = queue.isEmpty ? nil : queue
        return delivery
    }

    /// Pop a random next delivery across all connections.
    /// Cross-connection ordering is free; intra-connection order is preserved.
    mutating func popNext(using rng: inout DeterministicRNG) -> Event? {
        let nonemptyKeys = queues.filter { !$0.value.isEmpty }.keys.sorted()
        guard !nonemptyKeys.isEmpty else { return nil }
        let key = nonemptyKeys[rng.int(in: 0..<nonemptyKeys.count)]
        return dequeue(connection: key).map { .deliver($0) }
    }

    var isEmpty: Bool {
        queues.values.allSatisfy(\.isEmpty)
    }
}
