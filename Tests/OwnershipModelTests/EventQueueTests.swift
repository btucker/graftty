import Testing
import GrafttyProtocol

@Suite("EventQueue")
struct EventQueueTests {
    private func grid(_ c: UInt16, _ r: UInt16) -> DisplayGrid { try! DisplayGrid(cols: c, rows: r) }

    @Test func drainsAllPushedEvents() {
        var q = EventQueue()
        let ops: [Op] = (0..<5).map { .release(DisplayClientID("c\($0)")) }
        ops.forEach { q.push(.op($0)) }
        var rng = DeterministicRNG(seed: 99)
        var drained = 0
        while q.popNext(using: &rng) != nil { drained += 1 }
        #expect(drained == 5)
        #expect(q.isEmpty)
    }

    @Test func orderIsSeedDeterministic() {
        func run(_ seed: UInt64) -> [String] {
            var q = EventQueue()
            (0..<6).forEach { q.push(.op(.release(DisplayClientID("c\($0)")))) }
            var rng = DeterministicRNG(seed: seed)
            var out: [String] = []
            while let e = q.popNext(using: &rng), case let .op(.release(id)) = e { out.append(id.description) }
            return out
        }
        #expect(run(5) == run(5))
        #expect(run(5) != run(6))  // overwhelmingly likely; if it ever flakes, the RNG is broken
    }
}
