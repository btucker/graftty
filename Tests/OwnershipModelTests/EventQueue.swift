struct EventQueue {
    private var events: [Event] = []

    mutating func push(_ e: Event) {
        events.append(e)
    }

    mutating func popNext(using rng: inout DeterministicRNG) -> Event? {
        guard !events.isEmpty else { return nil }
        let i = rng.int(in: 0..<events.count)
        return events.remove(at: i)
    }

    var isEmpty: Bool {
        events.isEmpty
    }
}
