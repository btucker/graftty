import Testing
@testable import GrafttyProtocol

@Suite("@spec LAYOUT-2.199: When a user reorders pinned agents or projects, the application shall store a sortable fractional rank that always leaves room between two neighbors, so every device agrees on the order from the ranks alone.")
struct FractionalRankTests {
    @Test func betweenSortsStrictlyBetween() {
        for (low, high) in [("a", "b"), ("a0V", "a1"), ("Z", "a"), ("aV", "aW"), ("a", "a1"), ("0V", "1")] {
            let mid = FractionalRank.between(low, high)
            #expect(low < mid && mid < high, "\(low) \(mid) \(high)")
            #expect(FractionalRank.isValid(mid))
        }
    }

    @Test func betweenWithNilBounds() {
        let first = FractionalRank.between(nil, nil)
        #expect(FractionalRank.isValid(first))
        #expect(FractionalRank.between(first, nil) > first)
        #expect(FractionalRank.between(nil, first) < first)
    }

    @Test func thousandInsertsInOneGapStaySortedAndCompact() {
        var low = "a"
        let high = "b"
        for _ in 0..<1000 {
            let mid = FractionalRank.between(low, high)
            #expect(low < mid && mid < high)
            low = mid
        }
        var top = "a"
        for _ in 0..<1000 {
            let mid = FractionalRank.between(nil, top)
            #expect(mid < top)
            top = mid
        }
        #expect(low.utf8.count < 256)
        #expect(top.utf8.count < 256)
    }

    @Test func seedsAscend() {
        let seeds = (0..<500).map(FractionalRank.seed(index:))
        #expect(seeds == seeds.sorted())
        #expect(Set(seeds).count == 500)
        #expect(seeds.allSatisfy(FractionalRank.isValid))
        #expect(FractionalRank.between(seeds[0], seeds[1]) > seeds[0])
    }

    @Test func invalidOrLegacyRankTreatedAsNil() {
        #expect(!FractionalRank.isValid(""))
        #expect(!FractionalRank.isValid("a b"))
        #expect(!FractionalRank.isValid("a0"))
        #expect(!FractionalRank.isValid(String(repeating: "a", count: 2000)))
        let writes = RankPlacement.move("x", toIndex: 0, in: [.init(id: "y", rank: "bad rank"), .init(id: "x", rank: "b")])
        #expect(writes.map(\.id) == ["x"])
        #expect(FractionalRank.isValid(writes[0].rank))
    }
}

@Suite("@spec LAYOUT-2.200: When a dragged row lands between rows whose ranks tie, the application shall also rewrite the writable tied rows so the row lands exactly at the drop position on every device.")
struct RankPlacementTests {
    private func settled(_ rows: [RankPlacement.Row], _ writes: [RankPlacement.Write]) -> [String] {
        let updates = Dictionary(uniqueKeysWithValues: writes.map { ($0.id, $0.rank) })
        let ranked: [(id: String, rank: String)] = rows.map { row in (row.id, updates[row.id] ?? row.rank ?? "~") }
        let sorted = ranked.sorted { left, right in
            left.rank == right.rank ? left.id < right.id : left.rank < right.rank
        }
        return sorted.map(\.id)
    }

    @Test func moveBetweenDistinctNeighborsWritesOneRow() {
        let rows: [RankPlacement.Row] = [.init(id: "a", rank: "a"), .init(id: "b", rank: "b"), .init(id: "c", rank: "c")]
        let writes = RankPlacement.move("c", toIndex: 1, in: rows)
        #expect(writes.map(\.id) == ["c"])
        #expect(settled(rows, writes) == ["a", "c", "b"])
    }

    @Test func moveBetweenTiedNeighborsLandsExactlyThere() {
        let rows: [RankPlacement.Row] = [.init(id: "a", rank: "a"), .init(id: "b", rank: "a"), .init(id: "c", rank: "a"), .init(id: "d", rank: "b")]
        let writes = RankPlacement.move("d", toIndex: 1, in: rows)
        #expect(settled(rows, writes) == ["a", "d", "b", "c"])
        #expect(writes.count == 3)
    }

    @Test func moveAroundUnwritableTiedRowStillOrdersWritableRows() {
        let rows: [RankPlacement.Row] = [.init(id: "a", rank: "a"), .init(id: "b", rank: "a", isWritable: false), .init(id: "c", rank: "a"), .init(id: "d", rank: "b")]
        let writes = RankPlacement.move("d", toIndex: 1, in: rows)
        #expect(!writes.contains { $0.id == "b" })
        let order = settled(rows, writes)
        #expect(order.firstIndex(of: "d")! < order.firstIndex(of: "c")!)
        #expect(order.firstIndex(of: "a")! < order.firstIndex(of: "d")!)
    }

    @Test func moveBelowRanklessRowsStaysAboveThem() {
        let rows: [RankPlacement.Row] = [.init(id: "a", rank: "a"), .init(id: "b", rank: "b"), .init(id: "old", rank: nil, isWritable: false)]
        let writes = RankPlacement.move("a", toIndex: 2, in: rows)
        #expect(settled(rows, writes) == ["b", "a", "old"])
    }

    @Test func moveToOwnPositionWritesNothing() {
        let rows: [RankPlacement.Row] = [.init(id: "a", rank: "a"), .init(id: "b", rank: "b")]
        #expect(RankPlacement.move("b", toIndex: 1, in: rows).isEmpty)
        #expect(RankPlacement.move("nope", toIndex: 0, in: rows).isEmpty)
    }
}
