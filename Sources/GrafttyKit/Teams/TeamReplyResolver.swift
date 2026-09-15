import Foundation

public enum TeamReplyError: Error, Equatable, CustomStringConvertible {
    case messageNotFound
    case wrongRecipient
    case systemMessage
    case invalidSender
    case ambiguousSender
    case noFallback
    case emptyMessage

    public var description: String {
        switch self {
        case .messageNotFound: return "reply message ID was not found in this worktree's inbox"
        case .wrongRecipient: return "reply message belongs to another agent"
        case .systemMessage: return "system messages have no agent to reply to"
        case .invalidSender: return "stored message has an invalid sender address"
        case .ambiguousSender: return "stored sender address conflicts with another local worktree; refusing to misroute the reply"
        case .noFallback: return "stored sender has no runtime fallback"
        case .emptyMessage: return "team reply must not be empty"
        }
    }
}

/// Resolves replies from inbox provenance without inspecting message bodies or
/// looking up provider display names. Resolution never advances the inbox.
public struct TeamReplyResolver {
    private let inbox: TeamInbox

    public init(inbox: TeamInbox) { self.inbox = inbox }

    public func resolve(
        callerWorktree: String,
        callerAgentID: String?,
        messageID: String,
        fallback: Bool,
        text: String,
        priority: TeamInboxPriority,
        repos: [RepoEntry],
        teamsEnabled: Bool
    ) throws -> NotificationMessage {
        guard teamsEnabled else { throw TeamInboxRequestError.teamModeDisabled }
        guard let repo = repos.first(where: { $0.worktrees.contains(where: { $0.path == callerWorktree }) }) else {
            throw TeamInboxRequestError.callerNotTracked
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TeamReplyError.emptyMessage }
        guard let message = try inbox.messages(teamID: TeamLookup.id(forRepoPath: repo.path)).first(where: {
            $0.id == messageID && $0.to.worktree == callerWorktree
        }) else { throw TeamReplyError.messageNotFound }
        if let target = message.to.agentID, target != callerAgentID { throw TeamReplyError.wrongRecipient }
        if let runtime = message.to.runtime,
           callerAgentID.flatMap(TeamAgentIdentity.init(rawValue:))?.runtime.rawValue != runtime {
            throw TeamReplyError.wrongRecipient
        }
        guard !message.from.isSystem else { throw TeamReplyError.systemMessage }
        let sender = message.from
        let runtime = sender.runtime.flatMap(TeamHookRuntime.init(rawValue:))
        let identity = sender.agentID.flatMap(TeamAgentIdentity.init(rawValue:))
        guard sender.agentID == nil || identity != nil,
              sender.runtime == nil || runtime != nil,
              identity == nil || runtime == nil || identity?.runtime == runtime else {
            throw TeamReplyError.invalidSender
        }
        if fallback, runtime == nil { throw TeamReplyError.noFallback }
        let suffix = fallback ? runtime?.rawValue : (identity?.rawValue ?? runtime?.rawValue)
        let address: String
        if let remote = RemoteTeamAddress(rawValue: sender.worktree) {
            guard remote.suffix == nil else { throw TeamReplyError.invalidSender }
            address = try RemoteTeamAddress(deviceID: remote.deviceID, worktreePath: remote.worktreePath, suffix: suffix).rawValue
        } else {
            guard RemoteTeamAddress.isAbsolutePath(sender.worktree) else { throw TeamReplyError.invalidSender }
            // The legacy send parser accepts XML-escaped addresses and prefers
            // literal worktree paths over agent suffixes. Require the stored
            // path itself and reject a suffix that names a different worktree.
            guard repo.worktrees.contains(where: { $0.path == sender.worktree }) else {
                throw TeamInboxRequestError.recipientNotFound(name: sender.worktree, available: repo.worktrees.map(\.path))
            }
            address = sender.worktree + (suffix.map { "#" + $0 } ?? "")
            guard address == sender.worktree || !repo.worktrees.contains(where: { $0.path == address }) else {
                throw TeamReplyError.ambiguousSender
            }
        }
        return .teamSend(callerWorktree: callerWorktree, callerAgentID: callerAgentID, recipient: address, text: text, priority: priority)
    }

    /// Message IDs normally contain only timestamp and UUID characters. Quote
    /// even imported IDs so generated shell instructions remain literal.
    public static func command(messageID: String) -> String {
        let quoted = "'" + messageID.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "graftty team reply \(quoted) --stdin"
    }
}
