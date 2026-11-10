import Foundation

/// @spec LAYOUT-2.225
/// What a pinned agent's tile shows. A tile never moves: it lights up in place.
public enum PinnedTileState: Sendable, Equatable {
    /// A question, a notification, or a finished turn the person hasn't opened.
    case waiting
    case working
    /// The host is asleep, so its last report says nothing about now.
    case asleep
    case idle

    public static func resolve(status: SidebarRowStatus, isCached: Bool) -> PinnedTileState {
        if isCached { return .asleep }
        if status.waitsForUser { return .waiting }
        if case .working = status { return .working }
        return .idle
    }

    var spokenName: String? {
        switch self {
        case .waiting: return "waiting for you"
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
        let separators = CharacterSet(charactersIn: "-_/ ")
        return source.components(separatedBy: separators).first { !$0.isEmpty } ?? source
    }

    public static func accessibilityLabel(name: String, host: String?, state: PinnedTileState) -> String {
        ([name, host.map { "on \($0)" }, state.spokenName].compactMap { $0 }).joined(separator: ", ")
    }
}
