import Testing

@Suite("DeterministicRNG")
struct DeterministicRNGTests {
    @Test func sameSeedSameSequence() {
        var a = DeterministicRNG(seed: 0xABCD)
        var b = DeterministicRNG(seed: 0xABCD)
        let xs = (0..<8).map { _ in a.next() }
        let ys = (0..<8).map { _ in b.next() }
        #expect(xs == ys)
    }
    @Test func differentSeedDiffers() {
        var a = DeterministicRNG(seed: 1)
        var b = DeterministicRNG(seed: 2)
        #expect(a.next() != b.next())
    }
    @Test func pickIsInBounds() {
        var r = DeterministicRNG(seed: 7)
        for _ in 0..<100 { #expect((0..<3).contains(r.int(in: 0..<3))) }
    }
}
