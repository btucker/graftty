import Foundation

/// A deterministic generator for fuzz and stress tests: a 64-bit linear
/// congruential generator (Knuth's MMIX constants) with the state run
/// through a SplitMix64-style finalizer, so the low bits are usable too. The
/// same seed always replays the same sequence, so a failure names the seed
/// that reproduces it.
struct SeededGenerator: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }

    mutating func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0 ..< 1, using: &self) < probability
    }

    mutating func pick<Element>(_ elements: [Element]) -> Element {
        elements[int(in: 0 ... elements.count - 1)]
    }

    /// A string of `0 ... maxLength` pieces drawn from `alphabet`.
    mutating func string(from alphabet: [String], maxLength: Int) -> String {
        let length = int(in: 0 ... maxLength)
        var result = ""
        for _ in 0 ..< length {
            result += pick(alphabet)
        }
        return result
    }
}
