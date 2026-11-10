import Foundation

/// @spec LAYOUT-2.225
/// What a pinned agent's tile shows. A tile never moves: it lights up in place.
public enum PinnedTileState: Sendable, Equatable {
    /// A question or a notification: thick orange border.
    case waiting
    /// A finished turn the person hasn't opened: thin orange border.
    case finished
    case working
    /// The host is asleep, so its last report says nothing about now.
    case asleep
    case idle

    public static func resolve(status: SidebarRowStatus, isCached: Bool) -> PinnedTileState {
        if isCached { return .asleep }
        if status.needsAttention { return .waiting }
        if status.waitsForUser { return .finished }
        if case .working = status { return .working }
        return .idle
    }

    /// How heavy the orange border is: the more it asks of the person, the heavier.
    public var borderWidth: CGFloat {
        switch self {
        case .waiting: return 3
        case .finished: return 1.25
        case .working, .asleep, .idle: return 0
        }
    }

    var spokenName: String? {
        switch self {
        case .waiting: return "waiting for you"
        case .finished: return "finished, not yet opened"
        case .working: return "working"
        case .asleep: return "host asleep"
        case .idle: return nil
        }
    }
}

public enum PinnedTile {
    /// Four tiles across at the default sidebar width.
    public static let minimumWidth: CGFloat = 56

    /// @spec LAYOUT-2.226
    /// The word on a tile's caption band: the first part of the worktree's
    /// name, or the branch for the default checkout.
    public static func word(name: String, isMainCheckout: Bool, branch: String) -> String {
        let source = isMainCheckout ? branch : name
        return segments(source).first ?? source
    }

    public struct Name: Equatable, Sendable {
        public let name: String
        public let isMainCheckout: Bool
        public let branch: String

        public init(name: String, isMainCheckout: Bool, branch: String) {
            self.name = name; self.isMainCheckout = isMainCheckout; self.branch = branch
        }
    }

    /// The words for one grid. Tiles whose first word clashes use the first
    /// later part of their name that differs, so no two read the same.
    public static func words(for names: [Name]) -> [String] {
        let words = names.map { word(name: $0.name, isMainCheckout: $0.isMainCheckout, branch: $0.branch) }
        let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
        return zip(names, words).map { name, word in
            guard (counts[word] ?? 0) > 1, !name.isMainCheckout else { return word }
            return segments(name.name).first { $0 != word } ?? word
        }
    }

    private static func segments(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "-_/ ")).filter { !$0.isEmpty }
    }

    /// What hovering a tile on Mac says. A native tooltip never takes focus
    /// from the terminal the way a popover window could.
    public static func hoverText(name: String, host: String?, status: SidebarRowStatus) -> String {
        let heading = ([name] + (host.map { [$0] } ?? [])).joined(separator: " · ")
        let line: String?
        switch status {
        case .question(let text, _): line = "Needs your input: " + text
        case .notification(let text, _), .working(let text), .whereWeAre(let text, _): line = text
        case .none: line = nil
        }
        return ([heading] + (line.map { [$0] } ?? [])).joined(separator: "\n")
    }

    public static func accessibilityLabel(name: String, host: String?, state: PinnedTileState) -> String {
        ([name, host.map { "on \($0)" }, state.spokenName].compactMap { $0 }).joined(separator: ", ")
    }
}
