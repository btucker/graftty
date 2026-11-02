import Foundation
import GrafttyProtocol

public enum TeamHookRuntime: String, Codable, Sendable, Equatable, CaseIterable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public enum TeamHookEvent: String, Codable, Sendable, Equatable, CaseIterable {
    case sessionStart = "session-start"
    case userPromptSubmit = "user-prompt-submit"
    case preToolUse = "pre-tool-use"
    case postToolUse = "post-tool-use"
    case postToolUseFailure = "post-tool-use-failure"
    case permissionRequest = "permission-request"
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
        case .userPromptSubmit: return "UserPromptSubmit"
        case .preToolUse: return "PreToolUse"
        case .postToolUse: return "PostToolUse"
        case .postToolUseFailure: return "PostToolUseFailure"
        case .permissionRequest: return "PermissionRequest"
        case .stop: return "Stop"
        }
    }
}

public struct TeamInboxPageRequest: Sendable, Equatable {
    public let callerWorktree: String?
    public let callerAgentID: String?
    public let consuming: Bool
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
        callerAgentID: String? = nil,
        consuming: Bool = false,
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
        self.callerAgentID = callerAgentID
        self.consuming = consuming
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
    case addProject(path: String)
    case projectAddCapability
    case linuxSetupIdentity
    case completeLinuxSetup(LinuxHostSetupResult)
    case previewFiles(path: String, targets: [String], paneSessionName: String? = nil)
    case previewImage(path: String, target: String, paneSessionName: String? = nil)
    case offerResource(path: String, target: String, paneSessionName: String? = nil)
    case notify(path: String, text: String, clearAfter: TimeInterval? = nil, paneSessionName: String? = nil)
    case clear(path: String, paneSessionName: String? = nil)
    case listPanes(path: String)
    case listRemoteHosts
    case mcpBridge(MCPBridgeRequest)
    case mcpConnection(MCPConnectionRequest)
    case remoteSkills(host: RemoteMacConnectionSummary.ID, request: RemoteSkillTransferRequest)
    case remotePlacement(host: RemoteMacConnectionSummary.ID, request: HostPlacementRequest)
    case reconnectRemoteMac(target: String)
    case reconnectRemoteClient(target: String)
    case remoteWorktree(target: String, request: RemoteWorktreeRequest)
    case addPane(AddPaneRequest)
    case paneAgentCapability
    case closePane(path: String, index: Int)
    case showPane(path: String, index: Int, lines: Int)
    case sendPane(path: String, index: Int, text: String, pressEnter: Bool)
    case teamSend(TeamSendRequest)
    case teamReply(TeamReplyRequest)
    case teamBroadcast(
        callerWorktree: String,
        callerAgentID: String? = nil,
        text: String,
        priority: TeamInboxPriority
    )
    case teamHook(TeamHookRequest)
    case providerActivity(ProviderActivityRequest)
    case attentionReport(callerWorktree: String, callerAgentID: String, recap: AttentionRecap)
    case teamInbox(TeamInboxPageRequest)
    case teamInboxAdvance(
        callerWorktree: String,
        callerAgentID: String? = nil,
        throughID: String
    )
    case teamMembers(callerWorktree: String?, worktree: String?, repo: String?)
    case teamList(callerWorktree: String)
    case createWorktree(CreateWorktreeRequest)
    /// Asks which `ControlCapability` values the app supports (ATTN-2.27).
    case capabilities
    case agent(AgentControlRequest)
    case agentPromptStagingCapability
    case worktreeBaseCapability
    case worktreeCreateIdempotencyCapability
    case remoteWorktreeCapability
    case worktreeCreateStatus(operationID: String)
    case removeWorktree(worktreePath: String, force: Bool, pinned: Bool = false)
    case worktreeRemoveCapability
    case worktreePinnedRemovalCapability
    case worktreePinCapability
    case setWorktreePinned(worktreePath: String, isPinned: Bool)
    case worktreeRemoveStatus(operationID: String)
}

public extension NotificationMessage {
    var providerSleepActivity: ProviderSleepActivity? {
        switch self {
        case .teamHook(let request): return request.providerSleepActivity
        case .providerActivity(let request): return request.activity
        default: return nil
        }
    }

    // Labeled constructors for the payload cases, so call sites read like
    // the other cases.
    static func teamSend(callerWorktree: String, callerAgentID: String? = nil, recipient: String, text: String,
                         priority: TeamInboxPriority) -> Self {
        .teamSend(TeamSendRequest(callerWorktree: callerWorktree, callerAgentID: callerAgentID,
                                  recipient: recipient, text: text, priority: priority))
    }

    static func teamReply(callerWorktree: String, callerAgentID: String? = nil, messageID: String, text: String,
                          priority: TeamInboxPriority, fallback: Bool = false) -> Self {
        .teamReply(TeamReplyRequest(callerWorktree: callerWorktree, callerAgentID: callerAgentID,
                                    messageID: messageID, text: text, priority: priority, fallback: fallback))
    }

    static func teamHook(callerWorktree: String, callerAgentID: String? = nil, runtime: TeamHookRuntime,
                         event: TeamHookEvent, sessionID: String?, paneSessionName: String?,
                         attentionReason: AgentHookAttentionReason? = nil, stopHookActive: Bool = false,
                         providerSleepActivity: ProviderSleepActivity? = nil, turnID: String? = nil, fallbackReport: AttentionFileRecapEvent? = nil) -> Self {
        .teamHook(TeamHookRequest(callerWorktree: callerWorktree, callerAgentID: callerAgentID, runtime: runtime,
                                  event: event, sessionID: sessionID, paneSessionName: paneSessionName,
                                  attentionReason: attentionReason, stopHookActive: stopHookActive,
                                  providerSleepActivity: providerSleepActivity, turnID: turnID, fallbackReport: fallbackReport))
    }

    static func addPane(path: String, direction: PaneSplit, command: String?, agentRuntime: TeamHookRuntime? = nil,
                        agentPrompt: String? = nil) -> Self {
        .addPane(AddPaneRequest(path: path, direction: direction, command: command, agentRuntime: agentRuntime,
                                agentPrompt: agentPrompt))
    }

    static func createWorktree(callerWorktree: String, worktreeName: String, branchName: String, existing: Bool,
                               base: String?, command: String?, agentRuntime: TeamHookRuntime?, agentPrompt: String?,
                               operationID: String?) -> Self {
        .createWorktree(CreateWorktreeRequest(
            callerWorktree: callerWorktree, worktreeName: worktreeName, branchName: branchName, existing: existing,
            base: base, command: command, agentRuntime: agentRuntime, agentPrompt: agentPrompt,
            operationID: operationID))
    }

    static func providerActivity(callerWorktree: String, runtime: TeamHookRuntime, sessionID: String?,
                                 paneSessionName: String?, activity: ProviderSleepActivity) -> Self {
        .providerActivity(ProviderActivityRequest(callerWorktree: callerWorktree, runtime: runtime,
                                                  sessionID: sessionID, paneSessionName: paneSessionName,
                                                  activity: activity))
    }

    /// @spec ATTN-2.20: When the application receives a one-way `notify` or `clear` socket message, it shall dispatch the notification without registering or waiting on a response handler, so notification bursts cannot consume request-client capacity.
    var expectsResponse: Bool {
        switch self {
        case .notify, .clear, .providerActivity:
            return false
        default:
            return true
        }
    }
}

extension NotificationMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case targets
        case type, path, text, clearAfter, index, lines
        case target, request, result, host
        case callerWorktree = "caller_worktree"
        case callerAgentID = "caller_agent_id"
        case recipient, priority, worktree, repo, member, unread, all, limit, consuming
        case beforeID = "before_id"
        case afterID = "after_id"
        case snapshotThroughID = "snapshot_through_id"
        case forwardPagination = "forward_pagination"
        case throughID = "through_id"
        case worktreePath = "worktree_path"
        case force, pinned
        case isPinned = "is_pinned"
        case operationID = "operation_id"
        case paneSessionName = "pane_session_name"
        case recap
        case pressEnter = "press_enter"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addProject(let path):
            try container.encode("add_project", forKey: .type)
            try container.encode(path, forKey: .path)
        case .projectAddCapability:
            try container.encode("project_add_capability", forKey: .type)
        case .linuxSetupIdentity:
            try container.encode("linux_setup_identity", forKey: .type)
        case .completeLinuxSetup(let result):
            try container.encode("complete_linux_setup", forKey: .type)
            try container.encode(result, forKey: .result)
        case let .previewFiles(path, targets, paneSessionName):
            try container.encode("preview_files", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(targets, forKey: .targets)
            try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
        case let .previewImage(path, target, paneSessionName):
            try container.encode("preview_image", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
        case let .offerResource(path, target, paneSessionName):
            try container.encode("open_resource", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(target, forKey: .target)
            try container.encodeIfPresent(paneSessionName, forKey: .paneSessionName)
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
        case .mcpConnection(let request):
            try container.encode("mcp_connection", forKey: .type)
            try container.encode(request, forKey: .request)
        case .mcpBridge(let request):
            try container.encode("mcp_bridge", forKey: .type)
            try container.encode(request, forKey: .request)
        case .remoteSkills(let host, let request):
            try container.encode("remote_skills", forKey: .type)
            try container.encode(host, forKey: .host)
            try container.encode(request, forKey: .request)
        case .remotePlacement(let host, let request):
            try container.encode("remote_placement", forKey: .type)
            try container.encode(host, forKey: .host)
            try container.encode(request, forKey: .request)
        case .listRemoteHosts:
            try container.encode("list_remote_hosts", forKey: .type)
        case .reconnectRemoteMac(let target):
            try container.encode("reconnect_remote_mac", forKey: .type)
            try container.encode(target, forKey: .target)
        case .remoteWorktree(let target, let request):
            try container.encode("remote_worktree", forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(request, forKey: .request)
        case .reconnectRemoteClient(let target):
            try container.encode("reconnect_remote_client", forKey: .type)
            try container.encode(target, forKey: .target)
        case .addPane(let request):
            try container.encode("add_pane", forKey: .type)
            try request.encode(to: encoder)
        case .paneAgentCapability:
            try container.encode("pane_agent_capability", forKey: .type)
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
        case .teamSend(let request):
            try container.encode("team_send", forKey: .type)
            try request.encode(to: encoder)
        case .teamReply(let request):
            try container.encode("team_reply", forKey: .type)
            try request.encode(to: encoder)
        case .teamBroadcast(let path, let callerAgentID, let text, let priority):
            try container.encode("team_broadcast", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encodeIfPresent(callerAgentID, forKey: .callerAgentID)
            try container.encode(text, forKey: .text)
            try container.encode(priority, forKey: .priority)
        case .teamHook(let request):
            try container.encode("team_hook", forKey: .type)
            try request.encode(to: encoder)
        case .providerActivity(let request):
            try container.encode("provider_activity", forKey: .type)
            try request.encode(to: encoder)
        case .attentionReport(let path, let callerAgentID, let recap):
            try container.encode("attention_report", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
            try container.encode(callerAgentID, forKey: .callerAgentID)
            try container.encode(recap, forKey: .recap)
        case .teamInbox(let request):
            try container.encode("team_inbox", forKey: .type)
            try container.encodeIfPresent(request.callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(request.callerAgentID, forKey: .callerAgentID)
            try container.encode(request.consuming, forKey: .consuming)
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
        case .teamInboxAdvance(let callerWorktree, let callerAgentID, let throughID):
            try container.encode("team_inbox_advance", forKey: .type)
            try container.encode(callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(callerAgentID, forKey: .callerAgentID)
            try container.encode(throughID, forKey: .throughID)
        case .teamMembers(let callerWorktree, let worktree, let repo):
            try container.encode("team_members", forKey: .type)
            try container.encodeIfPresent(callerWorktree, forKey: .callerWorktree)
            try container.encodeIfPresent(worktree, forKey: .worktree)
            try container.encodeIfPresent(repo, forKey: .repo)
        case .teamList(let path):
            try container.encode("team_list", forKey: .type)
            try container.encode(path, forKey: .callerWorktree)
        case .createWorktree(let request):
            try container.encode("create_worktree", forKey: .type)
            try request.encode(to: encoder)
        case .agent(let request):
            try container.encode("agent", forKey: .type)
            try container.encode(request, forKey: .request)
        case .capabilities:
            try container.encode("capabilities", forKey: .type)
        case .agentPromptStagingCapability:
            try container.encode("agent_prompt_staging_capability", forKey: .type)
        case .worktreeBaseCapability:
            try container.encode("worktree_base_capability", forKey: .type)
        case .remoteWorktreeCapability:
            try container.encode("remote_worktree_capability", forKey: .type)
        case .worktreeCreateIdempotencyCapability:
            try container.encode("worktree_create_idempotency_capability", forKey: .type)
        case .worktreeCreateStatus(let operationID):
            try container.encode("worktree_create_status", forKey: .type)
            try container.encode(operationID, forKey: .operationID)
        case .removeWorktree(let worktreePath, let force, let pinned):
            try container.encode("remove_worktree", forKey: .type)
            try container.encode(worktreePath, forKey: .worktreePath)
            try container.encode(force, forKey: .force)
            try container.encode(pinned, forKey: .pinned)
        case .worktreePinCapability:
            try container.encode("worktree_pin_capability", forKey: .type)
        case .setWorktreePinned(let worktreePath, let isPinned):
            try container.encode("set_worktree_pinned", forKey: .type)
            try container.encode(worktreePath, forKey: .worktreePath)
            try container.encode(isPinned, forKey: .isPinned)
        case .worktreeRemoveCapability:
            try container.encode("worktree_remove_capability", forKey: .type)
        case .worktreePinnedRemovalCapability:
            try container.encode("worktree_pinned_removal_capability", forKey: .type)
        case .worktreeRemoveStatus(let operationID):
            try container.encode("worktree_remove_status", forKey: .type)
            try container.encode(operationID, forKey: .operationID)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "add_project":
            self = .addProject(path: try container.decode(String.self, forKey: .path))
        case "project_add_capability":
            self = .projectAddCapability
        case "linux_setup_identity":
            self = .linuxSetupIdentity
        case "complete_linux_setup":
            self = .completeLinuxSetup(try container.decode(LinuxHostSetupResult.self, forKey: .result))
        case "preview_files":
            self = .previewFiles(path: try container.decode(String.self, forKey: .path),
                                 targets: try container.decode([String].self, forKey: .targets),
                                 paneSessionName: try container.decodeIfPresent(String.self, forKey: .paneSessionName))
        case "preview_image":
            self = .previewImage(
                path: try container.decode(String.self, forKey: .path),
                target: try container.decode(String.self, forKey: .target),
                paneSessionName: try container.decodeIfPresent(String.self, forKey: .paneSessionName)
            )
        case "open_resource":
            self = .offerResource(
                path: try container.decode(String.self, forKey: .path),
                target: try container.decode(String.self, forKey: .target),
                paneSessionName: try container.decodeIfPresent(String.self, forKey: .paneSessionName)
            )
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
        case "mcp_connection":
            self = .mcpConnection(try container.decode(MCPConnectionRequest.self, forKey: .request))
        case "mcp_bridge":
            self = .mcpBridge(try container.decode(MCPBridgeRequest.self, forKey: .request))
        case "remote_skills":
            self = .remoteSkills(host: try container.decode(RemoteMacConnectionSummary.ID.self, forKey: .host), request: try container.decode(RemoteSkillTransferRequest.self, forKey: .request))
        case "remote_placement":
            self = .remotePlacement(host: try container.decode(RemoteMacConnectionSummary.ID.self, forKey: .host), request: try container.decode(HostPlacementRequest.self, forKey: .request))
        case "list_remote_hosts":
            self = .listRemoteHosts
        case "reconnect_remote_mac":
            self = .reconnectRemoteMac(target: try container.decode(String.self, forKey: .target))
        case "remote_worktree":
            self = .remoteWorktree(target: try container.decode(String.self, forKey: .target), request: try container.decode(RemoteWorktreeRequest.self, forKey: .request))
        case "reconnect_remote_client":
            self = .reconnectRemoteClient(target: try container.decode(String.self, forKey: .target))
        case "add_pane":
            self = .addPane(try AddPaneRequest(from: decoder))
        case "pane_agent_capability":
            self = .paneAgentCapability
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
            // ATTN-2.26: CLIs before `team send` existed sent this; it is a
            // normal-priority send with no caller agent.
            self = .teamSend(
                callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
                recipient: try container.decode(String.self, forKey: .recipient),
                text: try container.decode(String.self, forKey: .text),
                priority: .normal
            )
        case "team_send":
            self = .teamSend(try TeamSendRequest(from: decoder))
        case "team_reply":
            self = .teamReply(try TeamReplyRequest(from: decoder))
        case "team_broadcast":
            let path = try container.decode(String.self, forKey: .callerWorktree)
            let callerAgentID = try container.decodeIfPresent(String.self, forKey: .callerAgentID)
            let text = try container.decode(String.self, forKey: .text)
            let priority = try container.decode(TeamInboxPriority.self, forKey: .priority)
            self = .teamBroadcast(
                callerWorktree: path,
                callerAgentID: callerAgentID,
                text: text,
                priority: priority
            )
        case "team_hook":
            self = .teamHook(try TeamHookRequest(from: decoder))
        case "provider_activity":
            self = .providerActivity(try ProviderActivityRequest(from: decoder))
        case "attention_report":
            self = .attentionReport(
                callerWorktree: try container.decode(String.self, forKey: .callerWorktree),
                callerAgentID: try container.decode(String.self, forKey: .callerAgentID),
                recap: try container.decode(AttentionRecap.self, forKey: .recap)
            )
        case "team_inbox":
            let callerWorktree = try container.decodeIfPresent(String.self, forKey: .callerWorktree)
            let callerAgentID = try container.decodeIfPresent(String.self, forKey: .callerAgentID)
            let consuming = try container.decodeIfPresent(Bool.self, forKey: .consuming) ?? false
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
                callerAgentID: callerAgentID,
                consuming: consuming,
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
                callerAgentID: try container.decodeIfPresent(String.self, forKey: .callerAgentID),
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
            self = .createWorktree(try CreateWorktreeRequest(from: decoder))
        case "agent":
            self = .agent(try container.decode(AgentControlRequest.self, forKey: .request))
        case "capabilities":
            self = .capabilities
        case "agent_prompt_staging_capability":
            self = .agentPromptStagingCapability
        case "worktree_base_capability":
            self = .worktreeBaseCapability
        case "remote_worktree_capability":
            self = .remoteWorktreeCapability
        case "worktree_create_idempotency_capability":
            self = .worktreeCreateIdempotencyCapability
        case "worktree_create_status":
            self = .worktreeCreateStatus(
                operationID: try container.decode(String.self, forKey: .operationID)
            )
        case "remove_worktree":
            self = .removeWorktree(
                worktreePath: try container.decode(String.self, forKey: .worktreePath),
                force: try container.decode(Bool.self, forKey: .force),
                pinned: try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
            )
        case "worktree_pin_capability":
            self = .worktreePinCapability
        case "set_worktree_pinned":
            self = .setWorktreePinned(
                worktreePath: try container.decode(String.self, forKey: .worktreePath),
                isPinned: try container.decode(Bool.self, forKey: .isPinned)
            )
        case "worktree_remove_capability":
            self = .worktreeRemoveCapability
        case "worktree_pinned_removal_capability":
            self = .worktreePinnedRemovalCapability
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
    public var progress: WorktreeCreationProgress?

    public init(
        operationID: String,
        state: WorktreeCreateState,
        worktreePath: String,
        messageAddress: String,
        error: String? = nil,
        progress: WorktreeCreationProgress? = nil
    ) {
        self.operationID = operationID
        self.state = state
        self.worktreePath = worktreePath
        self.messageAddress = messageAddress
        self.error = error
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case state, error, progress
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

/// One observed top-level runtime nested beneath a worktree in `team list`.
/// The optional pane is the final hierarchy level; native sessions discovered
/// outside a mounted Graftty pane may legitimately omit it.
public struct TeamListAgent: Codable, Sendable, Equatable {
    public let id: String
    public let address: String
    public let runtime: TeamHookRuntime
    public let displayName: String?
    public let isReachable: Bool
    public let paneSessionName: String?

    public init(
        id: String,
        address: String,
        runtime: TeamHookRuntime,
        displayName: String?,
        isReachable: Bool,
        paneSessionName: String?
    ) {
        self.id = id
        self.address = address
        self.runtime = runtime
        self.displayName = displayName
        self.isReachable = isReachable
        self.paneSessionName = paneSessionName
    }

    enum CodingKeys: String, CodingKey {
        case id, address, runtime
        case displayName = "display_name"
        case isReachable = "is_reachable"
        case paneSessionName = "pane_session_name"
    }
}

public struct TeamListMember: Codable, Sendable, Equatable {
    public let name: String
    public let branch: String
    public let worktreePath: String
    public let isMainWorktree: Bool
    public let isRunning: Bool
    public let agents: [TeamListAgent]
    public let projectPath: String?
    public let projectName: String?

    public init(
        name: String,
        branch: String,
        worktreePath: String,
        isMainWorktree: Bool,
        isRunning: Bool,
        agents: [TeamListAgent] = [],
        projectPath: String? = nil,
        projectName: String? = nil
    ) {
        self.name = name
        self.branch = branch
        self.worktreePath = worktreePath
        self.isMainWorktree = isMainWorktree
        self.isRunning = isRunning
        self.agents = agents
        self.projectPath = projectPath
        self.projectName = projectName
    }

    enum CodingKeys: String, CodingKey {
        case name, branch, agents
        case worktreePath = "worktree_path"
        case isMainWorktree = "is_main_worktree"
        case isRunning = "is_running"
        case projectPath = "project_path"
        case projectName = "project_name"
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
            isRunning: try container.decode(Bool.self, forKey: .isRunning),
            agents: try container.decodeIfPresent([TeamListAgent].self, forKey: .agents) ?? [],
            projectPath: try container.decodeIfPresent(String.self, forKey: .projectPath),
            projectName: try container.decodeIfPresent(String.self, forKey: .projectName)
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
/// `NotificationMessage`. `ok` covers successful one-way commands;
/// `error` carries a human-readable failure; `serverBusy` is a reserved,
/// machine-readable transport signal that remains an ordinary error for
/// older clients;
/// `paneList` is the response to `listPanes`; `teamList` is the response to `teamList`.
public enum ResponseMessage: Sendable, Equatable {
    public static let serverBusyCode = "graftty.control-socket.busy.v1"
    public static let serverBusyMessage =
        "Control socket is busy; retry the command."

    case linuxSetupIdentity(LinuxHostTrustRequest)
    case mcpProxy(MCPProxyResponse)
    case mcpConnections([MCPConnectionStatus])
    case agentSkills(RemoteSkillTransferStatus)
    case placement(HostPlacementRecord)
    case remoteHosts([RemoteMacConnectionSummary])
    case ok
    case error(String)
    case serverBusy
    case paneList([PaneInfo])
    case paneShow(String)
    case teamList(teamName: String, members: [TeamListMember])
    case teamHookOutput(String)
    case teamInbox(messages: [TeamInboxMessage], nextBeforeID: String?, nextAfterID: String?, snapshotThroughID: String?)
    case worktreeCreate(WorktreeCreateStatus)
    case worktreeCreateRetry(operationID: String)
    case worktreeRemove(WorktreeRemoveStatus)
    /// `ControlCapability` raw values; unknown names from a newer app are kept.
    case capabilities([String])
    case agents([AgentControlRecord])
}

public extension ResponseMessage {
    /// The `type` tag this response carries on the wire.
    var wireType: String {
        switch self {
        case .mcpConnections: "mcp_connections"
        case .mcpProxy: "mcp_proxy"
        case .agentSkills: "agent_skills"
        case .placement: "placement"
        case .remoteHosts: "remote_hosts"
        case .linuxSetupIdentity: "linux_setup_identity"
        case .ok: "ok"
        case .error, .serverBusy: "error"
        case .paneList: "pane_list"
        case .paneShow: "pane_show"
        case .teamList: "team_list"
        case .teamHookOutput: "team_hook_output"
        case .teamInbox: "team_inbox"
        case .worktreeCreate: "worktree_create"
        case .worktreeCreateRetry: "worktree_create_retry"
        case .worktreeRemove: "worktree_remove"
        case .capabilities: "capabilities"
        case .agents: "agents"
        }
    }
}

extension ResponseMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, code, message, panes, output, messages, text, operation, identity, capabilities, hosts, placement, agentSkills, mcpProxy, mcpConnections
        case operationID = "operation_id"
        case teamName = "team_name"
        case members, agents
        case nextBeforeID = "next_before_id"
        case nextAfterID = "next_after_id"
        case snapshotThroughID = "snapshot_through_id"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wireType, forKey: .type)
        switch self {
        case .mcpConnections(let statuses):
            try container.encode(statuses, forKey: .mcpConnections)
        case .mcpProxy(let response):
            try container.encode(response, forKey: .mcpProxy)
        case .agentSkills(let status):
            try container.encode(status, forKey: .agentSkills)
        case .placement(let record):
            try container.encode(record, forKey: .placement)
        case .linuxSetupIdentity(let identity):
            try container.encode(identity, forKey: .identity)
        case .remoteHosts(let hosts):
            try container.encode(hosts, forKey: .hosts)
        case .ok:
            break
        case .error(let message):
            try container.encode(message, forKey: .message)
        case .serverBusy:
            try container.encode(Self.serverBusyCode, forKey: .code)
            try container.encode(Self.serverBusyMessage, forKey: .message)
        case .paneList(let panes):
            try container.encode(panes, forKey: .panes)
        case .paneShow(let text):
            try container.encode(text, forKey: .text)
        case .teamList(let teamName, let members):
            try container.encode(teamName, forKey: .teamName)
            try container.encode(members, forKey: .members)
        case .teamHookOutput(let output):
            try container.encode(output, forKey: .output)
        case .teamInbox(let messages, let nextBeforeID, let nextAfterID, let snapshotThroughID):
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(nextBeforeID, forKey: .nextBeforeID)
            try container.encodeIfPresent(nextAfterID, forKey: .nextAfterID)
            try container.encodeIfPresent(snapshotThroughID, forKey: .snapshotThroughID)
        case .worktreeCreateRetry(let operationID):
            try container.encode(operationID, forKey: .operationID)
        case .worktreeCreate(let operation):
            try container.encode(operation, forKey: .operation)
        case .worktreeRemove(let operation):
            try container.encode(operation, forKey: .operation)
        case .agents(let records):
            try container.encode(records, forKey: .agents)
        case .capabilities(let names):
            try container.encode(names, forKey: .capabilities)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "mcp_connections":
            self = .mcpConnections(try container.decode([MCPConnectionStatus].self, forKey: .mcpConnections))
        case "mcp_proxy":
            self = .mcpProxy(try container.decode(MCPProxyResponse.self, forKey: .mcpProxy))
        case "agent_skills":
            self = .agentSkills(try container.decode(RemoteSkillTransferStatus.self, forKey: .agentSkills))
        case "placement":
            self = .placement(try container.decode(HostPlacementRecord.self, forKey: .placement))
        case "linux_setup_identity":
            self = .linuxSetupIdentity(try container.decode(LinuxHostTrustRequest.self, forKey: .identity))
        case "remote_hosts":
            self = .remoteHosts(try container.decode([RemoteMacConnectionSummary].self, forKey: .hosts))
        case "ok":
            self = .ok
        case "error":
            let msg = try container.decode(String.self, forKey: .message)
            if try container.decodeIfPresent(String.self, forKey: .code)
                == Self.serverBusyCode || msg == Self.serverBusyCode {
                self = .serverBusy
            } else {
                self = .error(msg)
            }
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
        case "worktree_create_retry":
            self = .worktreeCreateRetry(operationID: try container.decode(String.self, forKey: .operationID))
        case "worktree_create":
            self = .worktreeCreate(
                try container.decode(WorktreeCreateStatus.self, forKey: .operation)
            )
        case "agents":
            self = .agents(try container.decode([AgentControlRecord].self, forKey: .agents))
        case "capabilities":
            self = .capabilities(try container.decode([String].self, forKey: .capabilities))
        case "worktree_remove":
            self = .worktreeRemove(
                try container.decode(WorktreeRemoveStatus.self, forKey: .operation)
            )
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown response type: \(type)"))
        }
    }
}
