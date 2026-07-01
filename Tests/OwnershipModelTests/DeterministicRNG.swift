struct DeterministicRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func int(in range: Range<Int>) -> Int {
        precondition(!range.isEmpty)
        return range.lowerBound + Int(next() % UInt64(range.count))
    }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(in: 0..<xs.count)] }
}
