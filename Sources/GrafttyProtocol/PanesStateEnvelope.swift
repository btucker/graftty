import Foundation

/// @spec REMOTE-6.2
/// Wire shape of a single `payload` frame on a `panes_state` channel.
/// Tagged-union JSON so future message types (deltas, presence pings)
/// can extend without breaking compatibility.
public enum PanesStateMessage: Sendable, Equatable {
    case snapshot([WorktreePanes])
}

extension PanesStateMessage: Codable {
    private enum CodingKeys: String, CodingKey { case type, worktrees }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .snapshot(let worktrees):
            try c.encode("snapshot", forKey: .type)
            try c.encode(worktrees, forKey: .worktrees)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "snapshot":
            let worktrees = try c.decode([WorktreePanes].self, forKey: .worktrees)
            self = .snapshot(worktrees)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown PanesStateMessage type: \(type)"
            )
        }
    }
}
