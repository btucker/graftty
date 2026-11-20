import Foundation

/// @spec LAYOUT-2.225
/// While a pinned agent is shown as a tile, the application shall show an orange dot before its name only while it asks for user input, a pulsing blue dot while it works even if a notification is pending, fade it while its host sleeps, and draw no dot otherwise, including after a turn stops.
public enum PinnedTileState: Sendable, Equatable {
    /// A request for user input: an orange dot.
    case waiting
    /// A finished turn the person hasn't opened; the tile draws no mark for it.
    case finished
    case working
    /// The host is asleep, so its last report says nothing about now.
    case asleep
    case idle

    public static func resolve(context: SidebarWorktreeContext, isCached: Bool) -> PinnedTileState {
        if isCached { return .asleep }
        if context.question != nil { return .waiting }
        if !context.workingPanes.isEmpty { return .working }
        if context.hasUnseenStop, context.worktree.sidebar?.unseenAgentStop?.notice == nil { return .finished }
        return .idle
    }

    /// The one small mark before a tile's name (LAYOUT-2.225).
    public enum Pip: Sendable, Equatable { case filled, pulse }

    /// Nil draws no mark: stopped and idle tiles carry nothing, and a sleeping host's tile fades instead.
    public var pip: Pip? {
        switch self {
        case .waiting: return .filled
        case .working: return .pulse
        // A stopped turn is not a request: it draws nothing.
        case .finished, .asleep, .idle: return nil
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
    /// The whole worktree name, or the branch for the default checkout; the tile
    /// truncates it with an ellipsis only when it is wider than the tile (LAYOUT-2.226).
    public static func word(name: String, isMainCheckout: Bool, branch: String) -> String {
        isMainCheckout ? branch : name
    }

    public struct Name: Equatable, Sendable {
        public let name: String
        public let isMainCheckout: Bool
        public let branch: String

        public init(name: String, isMainCheckout: Bool, branch: String) {
            self.name = name; self.isMainCheckout = isMainCheckout; self.branch = branch
        }
    }

    /// The host under each tile: only where another tile shows the same caption,
    /// such as two hosts' default checkouts (LAYOUT-2.242).
    public static func hostBadges(words: [String], hosts: [String?]) -> [String?] {
        let counts = Dictionary(words.map { ($0, 1) }, uniquingKeysWith: +)
        return zip(words, hosts).map { word, host in (counts[word] ?? 0) > 1 ? host : nil }
    }

    /// The captions for one grid. Whole names only clash when they are truly the
    /// same, such as two hosts' default checkouts, which the host badge resolves.
    public static func words(for names: [Name]) -> [String] {
        names.map { word(name: $0.name, isMainCheckout: $0.isMainCheckout, branch: $0.branch) }
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
