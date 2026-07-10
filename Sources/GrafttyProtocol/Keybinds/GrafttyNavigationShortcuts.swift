public enum GrafttyNavigationShortcuts {
    public enum CandidateSource: Sendable, Hashable {
        case fixedWorktree
        case fixedPane
        case host
    }

    public struct SourcedCandidate<Value> {
        public let source: CandidateSource
        public let value: Value

        public init(source: CandidateSource, value: Value) {
            self.source = source
            self.value = value
        }
    }

    public static let nextPane = ShortcutChord(key: "tab", modifiers: [.control])
    public static let previousPane = ShortcutChord(key: "tab", modifiers: [.control, .shift])
    public static let nextWorktree = ShortcutChord(key: "tab", modifiers: [.control, .option])
    public static let previousWorktree = ShortcutChord(key: "tab", modifiers: [.control, .option, .shift])

    public static func collisionWinners<Value, Identity: Hashable>(
        from candidates: [SourcedCandidate<Value>],
        identifiedBy identity: (Value) -> Identity
    ) -> [SourcedCandidate<Value>] {
        let sources: [CandidateSource] = [.fixedWorktree, .fixedPane, .host]
        var seen: Set<Identity> = []
        var winners: [SourcedCandidate<Value>] = []

        for source in sources {
            for candidate in candidates where candidate.source == source {
                guard seen.insert(identity(candidate.value)).inserted else { continue }
                winners.append(candidate)
            }
        }

        return winners
    }
}
