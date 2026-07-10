public enum GrafttyNavigationShortcuts {
    public enum CandidateSource: Sendable, Hashable {
        case fixedWorktree
        case fixedPane
        case host
    }

    public static let nextPane = ShortcutChord(key: "tab", modifiers: [.control])
    public static let previousPane = ShortcutChord(key: "tab", modifiers: [.control, .shift])
    public static let nextWorktree = ShortcutChord(key: "tab", modifiers: [.control, .option])
    public static let previousWorktree = ShortcutChord(key: "tab", modifiers: [.control, .option, .shift])

    public static let collisionPrecedence: [CandidateSource] = [
        .fixedWorktree,
        .fixedPane,
        .host,
    ]
}
