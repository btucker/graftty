import Foundation

public enum TeamHookRuntime: String, Codable, Sendable, Equatable {
    case codex
    case claude
}

public enum TeamHookEvent: String, Codable, Sendable, Equatable {
    case sessionStart = "session-start"
    case postToolUse = "post-tool-use"
    case stop
}

public enum NotificationMessage: Sendable, Equatable {
    case notify(path: String, text: String, clearAfter: TimeInterval? = nil)
    case clear(path: String)
    case listPanes(path: String)
    case addPane(path: String, direction: PaneSplit, command: String?)
    case closePane(path: String, index: Int)
    case teamMessage(callerWorktree: String, recipient: String, text: String)
    case teamSend(callerWorktree: String, recipient: String, text: String, priority: TeamInboxPriority)
    case teamBroadcast(callerWorktree: String, text: String, priority: TeamInboxPriority)
    case teamHook(callerWorktree: String, runtime: TeamHookRuntime, event: TeamHookEvent, sessionID: String?)
    case teamInbox(callerWorktree: String?, worktree: String?, repo: String?, member: String?, unread: Bool, all: Bool)
    case teamMembers(callerWorktree: String?, worktree: String?, repo: String?)
    case teamList(callerWorktree: String)
}

extension NotificationMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, path, text, clearAfter, direction, command, index
        case callerWorktree = "caller_worktree"
        case recipient, priority, runtime, event, worktree, repo, member, unread, all
        case sessionID = "session_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notify(let path, let text, let clearAfter):
            try container.encode("notify", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(clearAfter, forKey: .clearAfter)
        case .clear(let path):
            try container.encode("clear", forKey: .type)
            try container.encode(path, forKey: .path)
        case .listPanes(let path):
            try container.encode("list_panes", forKey: .type)
            try container.encode(path, forKey: .path)
        case .addPane(let path, let direction, let command):
            try container.encode("add_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(direction, forKey: .direction)
            try container.encodeIfPresent(command, forKey: .command)
        case .closePane(let path, let index):
            try container.encode("close_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(index, forKey: .index)
        case .teamMessage(let path, let recipient, let text):
            try container.encode("team_message", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encode(recipient, forKey: .recipient)
            try container.encode(text, forKey: .text)
        case .teamSend(let path, let recipient, let text, let priority):
            try container.encode("team_send", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encode(recipient, forKey: .recipient)
            try container.encode(text, forKey: .text)
            try container.encode(priority, forKey: .priority)
        case .teamBroadcast(let path, let text, let priority):
            try container.encode("team_broadcast", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encode(text, forKey: .text)
            try container.encode(priority, forKey: .priority)
        case .teamHook(let path, let runtime, let event, let sessionID):
            try container.encode("team_hook", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encode(runtime, forKey: .runtime)
            try container.encode(event, forKey: .event)
            try container.encodeIfPresent(sessionID, forKey: .sessionID)
        case .teamInbox(let callerWorktree, let worktree, let repo, let member, let unread, let all):
            try container.encode("team_inbox", forKey: .type)
            try container.encodeIfPresent(callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(worktree, forKey: .worktree)
            try container.encodeIfPresent(repo, forKey: .repo)
            try container.encodeIfPresent(member, forKey: .member)
            try container.encode(unread, forKey: .unread)
            try container.encode(all, forKey: .all)
        case .teamMembers(let callerWorktree, let worktree, let repo):
            try container.encode("team_members", forKey: .type)
            try container.encodeIfPresent(callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(worktree, forKey: .worktree)
            try container.encodeIfPresent(repo, forKey: .repo)
        case .teamList(let path):
            try container.encode("team_list", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "notify":
            let path = try container.decode(String.self, forKey: .path)
            let text = try container.decode(String.self, forKey: .text)
            let clearAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .clearAfter)
            self = .notify(path: path, text: text, clearAfter: clearAfter)
        case "clear":
            let path = try container.decode(String.self, forKey: .path)
            self = .clear(path: path)
        case "list_panes":
            let path = try container.decode(String.self, forKey: .path)
            self = .listPanes(path: path)
        case "add_pane":
            let path = try container.decode(String.self, forKey: .path)
            let direction = try container.decode(PaneSplit.self, forKey: .direction)
            let command = try container.decodeIfPresent(String.self, forKey: .command)
            self = .addPane(path: path, direction: direction, command: command)
        case "close_pane":
            let path = try container.decode(String.self, forKey: .path)
            let index = try container.decode(Int.self, forKey: .index)
            self = .closePane(path: path, index: index)
        case "team_message":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            let recipient = try container.decode(String.self, forKey: .recipient)
            let text = try container.decode(String.self, forKey: .text)
            self = .teamMessage(callerWorktree: path, recipient: recipient, text: text)
        case "team_send":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            let recipient = try container.decode(String.self, forKey: .recipient)
            let text = try container.decode(String.self, forKey: .text)
            let priority = try container.decode(TeamInboxPriority.self, forKey: .priority)
            self = .teamSend(callerWorktree: path, recipient: recipient, text: text, priority: priority)
        case "team_broadcast":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            let text = try container.decode(String.self, forKey: .text)
            let priority = try container.decode(TeamInboxPriority.self, forKey: .priority)
            self = .teamBroadcast(callerWorktree: path, text: text, priority: priority)
        case "team_hook":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            let runtime = try container.decode(TeamHookRuntime.self, forKey: .runtime)
            let event = try container.decode(TeamHookEvent.self, forKey: .event)
            let sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
            self = .teamHook(callerWorktree: path, runtime: runtime, event: event, sessionID: sessionID)
        case "team_inbox":
            let callerWorktree = try container.decodeIfPresent(String.self, forKey: .callerWorktree)
            let worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
            let repo = try container.decodeIfPresent(String.self, forKey: .repo)
            let member = try container.decodeIfPresent(String.self, forKey: .member)
            let unread = try container.decode(Bool.self, forKey: .unread)
            let all = try container.decode(Bool.self, forKey: .all)
            self = .teamInbox(callerWorktree: callerWorktree, worktree: worktree, repo: repo, member: member, unread: unread, all: all)
        case "team_members":
            let callerWorktree = try container.decodeIfPresent(String.self, forKey: .callerWorktree)
            let worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
            let repo = try container.decodeIfPresent(String.self, forKey: .repo)
            self = .teamMembers(callerWorktree: callerWorktree, worktree: worktree, repo: repo)
        case "team_list":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            self = .teamList(callerWorktree: path)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown message type: \(type)"))
        }
    }
}

/// One row in the response to a `listPanes` request. `id` is the 1-based
/// pane number within the worktree's split tree (see design spec). `title`
/// is the pane's OSC-0/OSC-2-reported title if any, otherwise nil.
public struct PaneInfo: Codable, Sendable, Equatable {
    public let id: Int
    public let title: String?
    public let focused: Bool

    public init(id: Int, title: String?, focused: Bool) {
        self.id = id
        self.title = title
        self.focused = focused
    }

    /// Row produced by `graftty pane list` for this pane. Extracted
    /// from the CLI so it's unit-testable without a running server.
    /// ATTN-1.11: id is right-padded to width 3 for typical layouts,
    /// but a single separator space is always inserted before the
    /// title regardless of id width — so pane IDs ≥ 100 don't collide
    /// visually with their title.
    ///
    /// A whitespace-only title is treated the same as nil / empty so
    /// the row clips cleanly; contentful titles with surrounding
    /// whitespace are preserved verbatim. Mirrors `PaneTitle.display`'s
    /// LAYOUT-2.14 behaviour for the `pane list` output surface.
    public func formattedLine() -> String {
        let marker = focused ? "*" : " "
        let idStr = String(id)
        let minWidth = 3
        let padLen = max(0, minWidth - idStr.count)
        let padding = String(repeating: " ", count: padLen)
        let renderedTitle: String? = {
            guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return title
        }()
        guard let renderedTitle else {
            return "\(marker) \(idStr)"
        }
        return "\(marker) \(idStr)\(padding) \(renderedTitle)"
    }
}

public struct TeamListMember: Codable, Sendable, Equatable {
    public let name: String
    public let branch: String
    public let worktreePath: String
    public let role: String   // "lead" | "coworker"
    public let isRunning: Bool

    public init(name: String, branch: String, worktreePath: String, role: String, isRunning: Bool) {
        self.name = name
        self.branch = branch
        self.worktreePath = worktreePath
        self.role = role
        self.isRunning = isRunning
    }

    enum CodingKeys: String, CodingKey {
        case name, branch
        case worktreePath = "worktree_path"
        case role
        case isRunning = "is_running"
    }
}

/// Reply sent from the app back to the CLI after a request-style
/// `NotificationMessage`. `ok` covers successful fire-and-forget commands;
/// `error` carries a human-readable message printed to the CLI's stderr;
/// `paneList` is the response to `listPanes`; `teamList` is the response to `teamList`.
public enum ResponseMessage: Sendable, Equatable {
    case ok
    case error(String)
    case paneList([PaneInfo])
    case teamList(teamName: String, members: [TeamListMember])
    case teamHookOutput(String)
    case teamInbox([TeamInboxMessage])
}

extension ResponseMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, message, panes, output, messages
        case teamName = "team_name"
        case members
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode("ok", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        case .paneList(let panes):
            try container.encode("pane_list", forKey: .type)
            try container.encode(panes, forKey: .panes)
        case .teamList(let teamName, let members):
            try container.encode("team_list", forKey: .type)
            try container.encode(teamName, forKey: .teamName)
            try container.encode(members, forKey: .members)
        case .teamHookOutput(let output):
            try container.encode("team_hook_output", forKey: .type)
            try container.encode(output, forKey: .output)
        case .teamInbox(let messages):
            try container.encode("team_inbox", forKey: .type)
            try container.encode(messages, forKey: .messages)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ok":
            self = .ok
        case "error":
            let msg = try container.decode(String.self, forKey: .message)
            self = .error(msg)
        case "pane_list":
            let panes = try container.decode([PaneInfo].self, forKey: .panes)
            self = .paneList(panes)
        case "team_list":
            let teamName = try container.decode(String.self, forKey: .teamName)
            let members = try container.decode([TeamListMember].self, forKey: .members)
            self = .teamList(teamName: teamName, members: members)
        case "team_hook_output":
            let output = try container.decode(String.self, forKey: .output)
            self = .teamHookOutput(output)
        case "team_inbox":
            let messages = try container.decode([TeamInboxMessage].self, forKey: .messages)
            self = .teamInbox(messages)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown response type: \(type)"))
        }
    }
}
