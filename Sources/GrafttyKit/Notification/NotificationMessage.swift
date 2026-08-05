import Foundation

public enum TeamHookRuntime: String, Codable, Sendable, Equatable {
    case codex
    case claude
}

public enum TeamHookEvent: String, Codable, Sendable, Equatable, CaseIterable {
    case sessionStart = "session-start"
    case postToolUse = "post-tool-use"
    case stop
}

public extension TeamHookEvent {
    /// Hook-config JSON key form, e.g. `.sessionStart` → `"SessionStart"`.
    /// Codex's `hooks.json` and Claude's inline `--settings` JSON both use
    /// these CamelCase event names, so this is the shared source of truth
    /// for `CodexHomeMirror` and `AgentHookInstaller`.
    var camelCaseKey: String {
        switch self {
        case .sessionStart: return "SessionStart"
        case .postToolUse: return "PostToolUse"
        case .stop: return "Stop"
        }
    }
}

public struct TeamInboxPageRequest: Sendable, Equatable {
    public let callerWorktree: String?
    public let worktree: String?
    public let repo: String?
    public let member: String?
    public let unread: Bool
    public let all: Bool
    public let beforeID: String?
    public let afterID: String?
    public let snapshotThroughID: String?
    public let forwardPagination: Bool?
    public let limit: Int?

    public init(
        callerWorktree: String?,
        worktree: String?,
        repo: String?,
        member: String?,
        unread: Bool,
        all: Bool,
        beforeID: String?,
        afterID: String?,
        snapshotThroughID: String?,
        forwardPagination: Bool?,
        limit: Int?
    ) {
        self.callerWorktree = callerWorktree
        self.worktree = worktree
        self.repo = repo
        self.member = member
        self.unread = unread
        self.all = all
        self.beforeID = beforeID
        self.afterID = afterID
        self.snapshotThroughID = snapshotThroughID
        self.forwardPagination = forwardPagination
        self.limit = limit
    }
}

public enum NotificationMessage: Sendable, Equatable {
    case notify(path: String, text: String, clearAfter: TimeInterval? = nil, paneSessionName: String? = nil)
    case clear(path: String, paneSessionName: String? = nil)
    case listPanes(path: String)
    case addPane(path: String, direction: PaneSplit, command: String?)
    case closePane(path: String, index: Int)
    case showPane(path: String, index: Int, lines: Int)
    case sendPane(path: String, index: Int, text: String, pressEnter: Bool)
    case teamMessage(callerWorktree: String, recipient: String, text: String)
    case teamSend(callerWorktree: String, recipient: String, text: String, priority: TeamInboxPriority)
    case teamBroadcast(callerWorktree: String, text: String, priority: TeamInboxPriority)
    case teamHook(callerWorktree: String, runtime: TeamHookRuntime, event: TeamHookEvent, sessionID: String?, paneSessionName: String?)
    case teamInbox(TeamInboxPageRequest)
    case teamInboxAdvance(callerWorktree: String, throughID: String)
    case teamMembers(callerWorktree: String?, worktree: String?, repo: String?)
    case teamList(callerWorktree: String)
    case createWorktree(
        callerWorktree: String,
        worktreeName: String,
        branchName: String,
        existing: Bool,
        base: String?,
        command: String?,
        agentRuntime: TeamHookRuntime?,
        agentPrompt: String?,
        operationID: String?
    )
    case agentPromptStagingCapability
    case worktreeBaseCapability
    case worktreeCreateIdempotencyCapability
    case worktreeCreateStatus(operationID: String)
    case removeWorktree(worktreePath: String, force: Bool)
    case worktreeRemoveCapability
    case worktreeRemoveStatus(operationID: String)
}

extension NotificationMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, path, text, clearAfter, direction, command, index, lines
        case callerWorktree = "caller_worktree"
        case recipient, priority, runtime, event, worktree, repo, member, unread, all, limit
        case beforeID = "before_id"
        case afterID = "after_id"
        case snapshotThroughID = "snapshot_through_id"
        case forwardPagination = "forward_pagination"
        case throughID = "through_id"
        case worktreeName = "worktree_name"
        case branchName = "branch_name"
        case worktreePath = "worktree_path"
        case base
        case force
        case operationID = "operation_id"
        case agentRuntime = "agent_runtime"
        case agentPrompt = "agent_prompt"
        case existing
        case sessionID = "session_id"
        case paneSessionName = "pane_session_name"
        case pressEnter = "press_enter"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notify(let path, let text, let clearAfter, let paneSessionName):
            try container.encode("notify", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(clearAfter, forKey: .clearAfter)
            try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
        case .clear(let path, let paneSessionName):
            try container.encode("clear", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
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
        case .showPane(let path, let index, let lines):
            try container.encode("show_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(index, forKey: .index)
            try container.encode(lines, forKey: .lines)
        case .sendPane(let path, let index, let text, let pressEnter):
            try container.encode("send_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(index, forKey: .index)
            try container.encode(text, forKey: .text)
            try container.encode(pressEnter, forKey: .pressEnter)
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
        case .teamHook(let path, let runtime, let event, let sessionID, let paneSessionName):
            try container.encode("team_hook", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encode(runtime, forKey: .runtime)
            try container.encode(event, forKey: .event)
            try container.encodeIfPresent(sessionID, forKey: .sessionID)
            try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
        case .teamInbox(let request):
            try container.encode("team_inbox", forKey: .type)
            try container.encodeIfPresent(request.callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(request.worktree, forKey: .worktree)
            try container.encodeIfPresent(request.repo, forKey: .repo)
            try container.encodeIfPresent(request.member, forKey: .member)
            try container.encode(request.unread, forKey: .unread)
            try container.encode(request.all, forKey: .all)
            try container.encodeIfPresent(request.beforeID, forKey: .beforeID)
            try container.encodeIfPresent(request.afterID, forKey: .afterID)
            try container.encodeIfPresent(request.snapshotThroughID, forKey: .snapshotThroughID)
            try container.encodeIfPresent(request.forwardPagination, forKey: .forwardPagination)
            try container.encodeIfPresent(request.limit, forKey: .limit)
        case .teamInboxAdvance(let callerWorktree, let throughID):
            try container.encode("team_inbox_advance", forKey: .type)
            try container.encode(callerWorktree, forKey: .callerWorktree)
            try container.encode(throughID, forKey: .throughID)
        case .teamMembers(let callerWorktree, let worktree, let repo):
            try container.encode("team_members", forKey: .type)
            try container.encodeIfPresent(callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(worktree, forKey: .worktree)
            try container.encodeIfPresent(repo, forKey: .repo)
        case .teamList(let path):
            try container.encode("team_list", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
        case .createWorktree(
            let callerWorktree,
            let worktreeName,
            let branchName,
            let existing,
            let base,
            let command,
            let agentRuntime,
            let agentPrompt,
            let operationID
        ):
            try container.encode("create_worktree", forKey: .type)
            try container.encode(callerWorktree, forKey: .callerWorktree)
            try container.encode(worktreeName, forKey: .worktreeName)
            try container.encode(branchName, forKey: .branchName)
            try container.encode(existing, forKey: .existing)
            try container.encodeIfPresent(base, forKey: .base)
            try container.encodeIfPresent(command, forKey: .command)
            try container.encodeIfPresent(agentRuntime, forKey: .agentRuntime)
            try container.encodeIfPresent(agentPrompt, forKey: .agentPrompt)
            try container.encodeIfPresent(operationID, forKey: .operationID)
        case .agentPromptStagingCapability:
            try container.encode("agent_prompt_staging_capability", forKey: .type)
        case .worktreeBaseCapability:
            try container.encode("worktree_base_capability", forKey: .type)
        case .worktreeCreateIdempotencyCapability:
            try container.encode("worktree_create_idempotency_capability", forKey: .type)
        case .worktreeCreateStatus(let operationID):
            try container.encode("worktree_create_status", forKey: .type)
            try container.encode(operationID, forKey: .operationID)
        case .removeWorktree(let worktreePath, let force):
            try container.encode("remove_worktree", forKey: .type)
            try container.encode(worktreePath, forKey: .worktreePath)
            try container.encode(force, forKey: .force)
        case .worktreeRemoveCapability:
            try container.encode("worktree_remove_capability", forKey: .type)
        case .worktreeRemoveStatus(let operationID):
            try container.encode("worktree_remove_status", forKey: .type)
            try container.encode(operationID, forKey: .operationID)
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
            let paneSessionName = try container.decodeIfPresent(String.self, forKey: .paneSessionName)
            self = .notify(path: path, text: text, clearAfter: clearAfter, paneSessionName: paneSessionName)
        case "clear":
            let path = try container.decode(String.self, forKey: .path)
            let paneSessionName = try container.decodeIfPresent(String.self, forKey: .paneSessionName)
            self = .clear(path: path, paneSessionName: paneSessionName)
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
        case "show_pane":
            let path = try container.decode(String.self, forKey: .path)
            let index = try container.decode(Int.self, forKey: .index)
            let lines = try container.decode(Int.self, forKey: .lines)
            self = .showPane(path: path, index: index, lines: lines)
        case "send_pane":
            let path = try container.decode(String.self, forKey: .path)
            let index = try container.decode(Int.self, forKey: .index)
            let text = try container.decode(String.self, forKey: .text)
            let pressEnter = try container.decode(Bool.self, forKey: .pressEnter)
            self = .sendPane(path: path, index: index, text: text, pressEnter: pressEnter)
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
            let paneSessionName = try container.decodeIfPresent(String.self, forKey: .paneSessionName)
            self = .teamHook(callerWorktree: path, runtime: runtime, event: event,
                             sessionID: sessionID, paneSessionName: paneSessionName)
        case "team_inbox":
            let callerWorktree = try container.decodeIfPresent(String.self, forKey: .callerWorktree)
            let worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
            let repo = try container.decodeIfPresent(String.self, forKey: .repo)
            let member = try container.decodeIfPresent(String.self, forKey: .member)
            let unread = try container.decode(Bool.self, forKey: .unread)
            let all = try container.decode(Bool.self, forKey: .all)
            let beforeID = try container.decodeIfPresent(String.self, forKey: .beforeID)
            let afterID = try container.decodeIfPresent(String.self, forKey: .afterID)
            let snapshotThroughID = try container.decodeIfPresent(String.self, forKey: .snapshotThroughID)
            let forwardPagination = try container.decodeIfPresent(Bool.self, forKey: .forwardPagination)
            let limit = try container.decodeIfPresent(Int.self, forKey: .limit)
            self = .teamInbox(TeamInboxPageRequest(
                callerWorktree: callerWorktree,
                worktree: worktree,
                repo: repo,
                member: member,
                unread: unread,
                all: all,
                beforeID: beforeID,
                afterID: afterID,
                snapshotThroughID: snapshotThroughID,
                forwardPagination: forwardPagination,
                limit: limit
            ))
        case "team_inbox_advance":
            self = .teamInboxAdvance(
                callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
                throughID: try container.decode(String.self, forKey: .throughID)
            )
        case "team_members":
            let callerWorktree = try container.decodeIfPresent(String.self, forKey: .callerWorktree)
            let worktree = try container.decodeIfPresent(String.self, forKey: .worktree)
            let repo = try container.decodeIfPresent(String.self, forKey: .repo)
            self = .teamMembers(callerWorktree: callerWorktree, worktree: worktree, repo: repo)
        case "team_list":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            self = .teamList(callerWorktree: path)
        case "create_worktree":
            self = .createWorktree(
                callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
                worktreeName: try container.decode(String.self, forKey: .worktreeName),
                branchName: try container.decode(String.self, forKey: .branchName),
                existing: try container.decode(Bool.self, forKey: .existing),
                base: try container.decodeIfPresent(String.self, forKey: .base),
                command: try container.decodeIfPresent(String.self, forKey: .command),
                agentRuntime: try container.decodeIfPresent(TeamHookRuntime.self, forKey: .agentRuntime),
                agentPrompt: try container.decodeIfPresent(String.self, forKey: .agentPrompt),
                operationID: try container.decodeIfPresent(String.self, forKey: .operationID)
            )
        case "agent_prompt_staging_capability":
            self = .agentPromptStagingCapability
        case "worktree_base_capability":
            self = .worktreeBaseCapability
        case "worktree_create_idempotency_capability":
            self = .worktreeCreateIdempotencyCapability
        case "worktree_create_status":
            self = .worktreeCreateStatus(
                operationID: try container.decode(String.self, forKey: .operationID)
            )
        case "remove_worktree":
            self = .removeWorktree(
                worktreePath: try container.decode(String.self, forKey: .worktreePath),
                force: try container.decode(Bool.self, forKey: .force)
            )
        case "worktree_remove_capability":
            self = .worktreeRemoveCapability
        case "worktree_remove_status":
            self = .worktreeRemoveStatus(
                operationID: try container.decode(String.self, forKey: .operationID)
            )
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown message type: \(type)"))
        }
    }
}

/// @spec AGENT-5.2
/// While a CLI worktree-creation operation is retained, the application shall expose exactly one pending, ready, or failed state by operation ID, together with the canonical worktree path used as its stable messaging address.
public enum WorktreeCreateState: String, Codable, Sendable, Equatable {
    case pending
    case ready
    case failed
}

/// Snapshot returned while a CLI-created worktree moves through Git,
/// discovery, terminal creation, and optional agent launch. The operation ID
/// lets the CLI poll without holding the serial control socket open while Git
/// hooks run.
public struct WorktreeCreateStatus: Codable, Sendable, Equatable {
    public let operationID: String
    public let state: WorktreeCreateState
    public let worktreePath: String
    public let messageAddress: String
    public let error: String?

    public init(
        operationID: String,
        state: WorktreeCreateState,
        worktreePath: String,
        messageAddress: String,
        error: String? = nil
    ) {
        self.operationID = operationID
        self.state = state
        self.worktreePath = worktreePath
        self.messageAddress = messageAddress
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case state, error
        case operationID = "operation_id"
        case worktreePath = "worktree_path"
        case messageAddress = "message_address"
    }
}

public enum WorktreeRemoveState: String, Codable, Sendable, Equatable {
    case pending
    case removed
    case failed
}

/// Snapshot returned while a CLI-requested worktree removal moves through
/// Git, terminal teardown, and model cleanup.
public struct WorktreeRemoveStatus: Codable, Sendable, Equatable {
    public let operationID: String
    public let state: WorktreeRemoveState
    public let worktreePath: String
    public let error: String?
    public let forceAllowed: Bool
    public let shortStatus: String?

    public init(
        operationID: String,
        state: WorktreeRemoveState,
        worktreePath: String,
        error: String? = nil,
        forceAllowed: Bool = false,
        shortStatus: String? = nil
    ) {
        self.operationID = operationID
        self.state = state
        self.worktreePath = worktreePath
        self.error = error
        self.forceAllowed = forceAllowed
        self.shortStatus = shortStatus
    }

    enum CodingKeys: String, CodingKey {
        case state, error
        case operationID = "operation_id"
        case worktreePath = "worktree_path"
        case forceAllowed = "force_allowed"
        case shortStatus = "short_status"
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
    public let isMainWorktree: Bool
    public let isRunning: Bool

    public init(
        name: String,
        branch: String,
        worktreePath: String,
        isMainWorktree: Bool,
        isRunning: Bool
    ) {
        self.name = name
        self.branch = branch
        self.worktreePath = worktreePath
        self.isMainWorktree = isMainWorktree
        self.isRunning = isRunning
    }

    enum CodingKeys: String, CodingKey {
        case name, branch
        case worktreePath = "worktree_path"
        case isMainWorktree = "is_main_worktree"
        case isRunning = "is_running"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case role
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let isMainWorktree: Bool
        if let value = try container.decodeIfPresent(Bool.self, forKey: .isMainWorktree) {
            isMainWorktree = value
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let role = try legacy.decode(String.self, forKey: .role)
            switch role {
            case "lead":
                isMainWorktree = true
            case "coworker":
                isMainWorktree = false
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .role,
                    in: legacy,
                    debugDescription: "Unknown legacy team member role: \(role)"
                )
            }
        }

        self.init(
            name: try container.decode(String.self, forKey: .name),
            branch: try container.decode(String.self, forKey: .branch),
            worktreePath: try container.decode(String.self, forKey: .worktreePath),
            isMainWorktree: isMainWorktree,
            isRunning: try container.decode(Bool.self, forKey: .isRunning)
        )
    }
}

/// Stable JSON document emitted by `graftty team list --json` and
/// `graftty team members --json`.
///
/// @spec TEAM-4.6
/// When a team member-list command is invoked with `--json`, the CLI shall
/// emit a Codable document with `team` and `members`, using the existing
/// snake_case `TeamListMember` wire keys rather than human-formatted rows.
public struct TeamListDocument: Codable, Sendable, Equatable {
    public let team: String
    public let members: [TeamListMember]

    public init(team: String, members: [TeamListMember]) {
        self.team = team
        self.members = members
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
    case paneShow(String)
    case teamList(teamName: String, members: [TeamListMember])
    case teamHookOutput(String)
    case teamInbox(messages: [TeamInboxMessage], nextBeforeID: String?, nextAfterID: String?, snapshotThroughID: String?)
    case worktreeCreate(WorktreeCreateStatus)
    case worktreeRemove(WorktreeRemoveStatus)
}

extension ResponseMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, message, panes, output, messages, text, operation
        case teamName = "team_name"
        case members
        case nextBeforeID = "next_before_id"
        case nextAfterID = "next_after_id"
        case snapshotThroughID = "snapshot_through_id"
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
        case .paneShow(let text):
            try container.encode("pane_show", forKey: .type)
            try container.encode(text, forKey: .text)
        case .teamList(let teamName, let members):
            try container.encode("team_list", forKey: .type)
            try container.encode(teamName, forKey: .teamName)
            try container.encode(members, forKey: .members)
        case .teamHookOutput(let output):
            try container.encode("team_hook_output", forKey: .type)
            try container.encode(output, forKey: .output)
        case .teamInbox(let messages, let nextBeforeID, let nextAfterID, let snapshotThroughID):
            try container.encode("team_inbox", forKey: .type)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(nextBeforeID, forKey: .nextBeforeID)
            try container.encodeIfPresent(nextAfterID, forKey: .nextAfterID)
            try container.encodeIfPresent(snapshotThroughID, forKey: .snapshotThroughID)
        case .worktreeCreate(let operation):
            try container.encode("worktree_create", forKey: .type)
            try container.encode(operation, forKey: .operation)
        case .worktreeRemove(let operation):
            try container.encode("worktree_remove", forKey: .type)
            try container.encode(operation, forKey: .operation)
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
        case "pane_show":
            let text = try container.decode(String.self, forKey: .text)
            self = .paneShow(text)
        case "team_list":
            let teamName = try container.decode(String.self, forKey: .teamName)
            let members = try container.decode([TeamListMember].self, forKey: .members)
            self = .teamList(teamName: teamName, members: members)
        case "team_hook_output":
            let output = try container.decode(String.self, forKey: .output)
            self = .teamHookOutput(output)
        case "team_inbox":
            let messages = try container.decode([TeamInboxMessage].self, forKey: .messages)
            let nextBeforeID = try container.decodeIfPresent(String.self, forKey: .nextBeforeID)
            let nextAfterID = try container.decodeIfPresent(String.self, forKey: .nextAfterID)
            let snapshotThroughID = try container.decodeIfPresent(String.self, forKey: .snapshotThroughID)
            self = .teamInbox(messages: messages, nextBeforeID: nextBeforeID, nextAfterID: nextAfterID, snapshotThroughID: snapshotThroughID)
        case "worktree_create":
            self = .worktreeCreate(
                try container.decode(WorktreeCreateStatus.self, forKey: .operation)
            )
        case "worktree_remove":
            self = .worktreeRemove(
                try container.decode(WorktreeRemoveStatus.self, forKey: .operation)
            )
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown response type: \(type)"))
        }
    }
}
