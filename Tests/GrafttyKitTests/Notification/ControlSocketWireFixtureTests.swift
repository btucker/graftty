import Testing
import Foundation
import GrafttyProtocol
@testable import GrafttyKit

/// Frozen control-socket JSON. The CLI binary updates with the app bundle
/// while an older app process keeps running, so every `type` tag and key
/// below is a contract with released builds. A failure here means a wire
/// change, not a stale fixture: keep the old spelling decodable instead of
/// editing the expected JSON.
@Suite("@spec ATTN-2.25: The control-socket protocol shall keep every request and response type tag and field key stable across releases, and shall keep decoding the optional fields that older peers omit, so an older running application keeps serving a newer CLI.")
struct ControlSocketWireFixtureTests {
    // Nested payloads mostly use synthesized Codable, so a Swift rename alone
    // changes their keys; they are frozen in full rather than spliced in.
    static let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static func host() throws -> RemoteMacConnectionSummary.ID {
        .init(deviceID: .init(value: "worker"), fingerprint: try .init(rawBytes: Data(repeating: 0, count: 32)))
    }
    static let skillStatus = RemoteSkillTransferStatus(descriptor: .init(operationID: operationID,
        repositoryID: "/repo", runtime: "codex", revision: "rev", byteCount: 12), receivedBytes: 12, phase: .staged)
    static func placement() throws -> HostPlacementRecord {
        .init(operationID: operationID, owner: try host(),
            intent: .init(repositoryID: "/repo", worktreeName: "wt", branchName: "wt",
                demand: .init(architecture: "arm64", cpus: 1, memoryBytes: 1024, diskBytes: 2048)),
            admittedAt: Date(timeIntervalSince1970: 0))
    }
    static let recap = AttentionRecap(
        title: "Fix auth", context: "Login", completed: "Tests pass", next: "Open PR", need: "Review",
        emoji: "e1", emojiAlternatives: ["e2"], purposeChanged: true, checkpoint: "Green", decisions: ["JWT"])
    static let remoteCreate = RemoteWorktreeRequest.create(RemoteWorktreeCreation(
        callerWorktree: "/r", project: "app", worktreeName: "wt", branchName: "br", existing: false,
        base: "main", command: "codex", agentRuntime: .codex, agentPrompt: "go", operationID: "op"))
    static let remoteOriginCreate: RemoteWorktreeRequest = {
        var creation = RemoteWorktreeCreation(
            callerWorktree: "/r", project: nil, worktreeName: "wt", branchName: "wt", existing: false,
            base: nil, command: nil, agentRuntime: nil, agentPrompt: nil, operationID: "op")
        creation.origin = GitRepositoryOrigin.parse("ssh://deploy@git.example.com:2222/srv/app.git")
        return .create(creation)
    }()
    static func setupResult() throws -> LinuxHostSetupResult {
        LinuxHostSetupResult(identity: .init(deviceID: "dev", displayName: "Linux", publicKey: "key", port: 8801),
                             openSSH: try .parse("hostname h\nuser u\nport 22\n"), destination: try .init("alias"),
                             projectPaths: ["/home/u/app"],
                             toolOutcomes: [.init(component: .codex, status: .succeeded, message: "ok")])
    }
    static let trust = LinuxHostTrustRequest(deviceID: "dev", displayName: "Mac", publicKey: "key")
    static let inboxMessage = TeamInboxMessage(
        id: "0001", batchID: "batch", createdAt: Date(timeIntervalSince1970: 0), team: "t", repoPath: "/r",
        from: .init(member: "a", worktree: "/r/a", runtime: "codex", agentID: "codex-1"),
        to: .init(member: "b", worktree: "/r/b", runtime: nil),
        priority: .normal, body: "hi", agentPrompt: "prompt", source: "github")
    static let member = TeamListMember(name: "main", branch: "main", worktreePath: "/r",
                                       isMainWorktree: true, isRunning: false)
    static let memberWithAgent = TeamListMember(
        name: "wt", branch: "wt", worktreePath: "/r/wt", isMainWorktree: false, isRunning: true,
        agents: [TeamListAgent(id: "codex-1", address: "/r/wt#codex-1", runtime: .codex, displayName: "Codex",
                               isReachable: true, paneSessionName: "s")],
        projectPath: "/r", projectName: "app")
    static let createStatus = WorktreeCreateStatus(operationID: "op", state: .failed, worktreePath: "/r/wt",
                                                   messageAddress: "/r/wt", error: "boom")
    static let removeStatus = WorktreeRemoveStatus(operationID: "op", state: .failed, worktreePath: "/r/wt",
                                                   error: "dirty", forceAllowed: true, shortStatus: "M a")

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func requests() throws -> [(NotificationMessage, String)] {
        [
            (.mcpBridge(.init(parent: try host(), request: .close(sessionID: operationID))),
             #"{"request":{"parent":{"deviceID":{"value":"worker"},"fingerprint":{"rawBytes":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}},"request":{"close":{"sessionID":"00000000-0000-0000-0000-000000000001"}}},"type":"mcp_bridge"}"#),
            (.listRemoteHosts,
             #"{"type":"list_remote_hosts"}"#),
            (.remoteSkills(host: try host(), request: .finish(operationID: operationID)),
             #"{"host":{"deviceID":{"value":"worker"},"fingerprint":{"rawBytes":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}},"request":{"finish":{"operationID":"00000000-0000-0000-0000-000000000001"}},"type":"remote_skills"}"#),
            (.remotePlacement(host: try host(), request: .status(operationID: operationID)),
             #"{"host":{"deviceID":{"value":"worker"},"fingerprint":{"rawBytes":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}},"request":{"status":{"operationID":"00000000-0000-0000-0000-000000000001"}},"type":"remote_placement"}"#),
            (.mcpConnection(.list), #"{"request":{"list":{}},"type":"mcp_connection"}"#),
            (.addProject(path: "/repo"), #"{"path":"/repo","type":"add_project"}"#),
            (.projectAddCapability, #"{"type":"project_add_capability"}"#),
            (.linuxSetupIdentity, #"{"type":"linux_setup_identity"}"#),
            (.completeLinuxSetup(try setupResult()),
             #"{"result":{"destination":"alias","identity":{"deviceID":"dev","displayName":"Linux","port":8801,"publicKey":"key"},"openSSH":{"hostname":"h","port":22,"user":"u"},"projectPaths":["/home/u/app"],"toolOutcomes":[{"component":"codex","message":"ok","status":"succeeded"}]},"type":"complete_linux_setup"}"#),
            (.previewFiles(path: "/r", targets: ["a.md"], paneSessionName: "s"),
             #"{"pane_session_name":"s","path":"/r","targets":["a.md"],"type":"preview_files"}"#),
            (.previewImage(path: "/r", target: "a.png", paneSessionName: "s"),
             #"{"pane_session_name":"s","path":"/r","target":"a.png","type":"preview_image"}"#),
            (.offerResource(path: "/r", target: "a.pdf", paneSessionName: "s"),
             #"{"pane_session_name":"s","path":"/r","target":"a.pdf","type":"open_resource"}"#),
            (.notify(path: "/r", text: "hi", clearAfter: 5, paneSessionName: "s"),
             #"{"clearAfter":5,"pane_session_name":"s","path":"/r","text":"hi","type":"notify"}"#),
            (.clear(path: "/r", paneSessionName: "s"), #"{"pane_session_name":"s","path":"/r","type":"clear"}"#),
            (.listPanes(path: "/r"), #"{"path":"/r","type":"list_panes"}"#),
            (.reconnectRemoteMac(target: "Studio"), #"{"target":"Studio","type":"reconnect_remote_mac"}"#),
            (.reconnectRemoteClient(target: "iPad"), #"{"target":"iPad","type":"reconnect_remote_client"}"#),
            (.remoteWorktree(target: "Studio", request: remoteCreate),
             #"{"request":{"create":{"_0":{"agentPrompt":"go","agentRuntime":"codex","base":"main","branchName":"br","callerWorktree":"/r","command":"codex","existing":false,"operationID":"op","project":"app","worktreeName":"wt"}}},"target":"Studio","type":"remote_worktree"}"#),
            (.remoteWorktree(target: "Studio", request: .status(operationID: "op")),
             #"{"request":{"status":{"operationID":"op"}},"target":"Studio","type":"remote_worktree"}"#),
            (.remoteWorktree(target: "Studio", request: remoteOriginCreate),
             #"{"request":{"create":{"_0":{"branchName":"wt","callerWorktree":"/r","existing":false,"operationID":"op","origin":{"host":"git.example.com","path":"/srv/app.git","port":2222,"sshUser":"deploy","transport":"ssh"},"worktreeName":"wt"}}},"target":"Studio","type":"remote_worktree"}"#),
            (.addPane(path: "/r", direction: .down, command: "ls", agentRuntime: .codex, agentPrompt: "go"),
             #"{"agent_prompt":"go","agent_runtime":"codex","command":"ls","direction":"down","path":"/r","type":"add_pane"}"#),
            (.paneAgentCapability, #"{"type":"pane_agent_capability"}"#),
            (.closePane(path: "/r", index: 2), #"{"index":2,"path":"/r","type":"close_pane"}"#),
            (.showPane(path: "/r", index: 2, lines: 50), #"{"index":2,"lines":50,"path":"/r","type":"show_pane"}"#),
            (.sendPane(path: "/r", index: 2, text: "ls", pressEnter: true),
             #"{"index":2,"path":"/r","press_enter":true,"text":"ls","type":"send_pane"}"#),
            (.teamSend(callerWorktree: "/r", callerAgentID: "codex-1", recipient: "b", text: "hi", priority: .urgent),
             #"{"caller_agent_id":"codex-1","caller_worktree":"/r","priority":"urgent","recipient":"b","text":"hi","type":"team_send"}"#),
            (.teamReply(callerWorktree: "/r", callerAgentID: "codex-1", messageID: "0001", text: "ok",
                        priority: .normal, fallback: true),
             #"{"caller_agent_id":"codex-1","caller_worktree":"/r","fallback":true,"message_id":"0001","priority":"normal","text":"ok","type":"team_reply"}"#),
            (.teamBroadcast(callerWorktree: "/r", callerAgentID: "codex-1", text: "hi", priority: .normal),
             #"{"caller_agent_id":"codex-1","caller_worktree":"/r","priority":"normal","text":"hi","type":"team_broadcast"}"#),
            (.teamHook(callerWorktree: "/r", callerAgentID: "claude-1", runtime: .claude, event: .permissionRequest,
                       sessionID: "sess", paneSessionName: "s", attentionReason: .planReview, stopHookActive: true,
                       providerSleepActivity: .busy),
             #"{"attention_reason":"plan_review","caller_agent_id":"claude-1","caller_worktree":"/r","event":"permission-request","pane_session_name":"s","provider_sleep_activity":"busy","runtime":"claude","session_id":"sess","stop_hook_active":true,"type":"team_hook"}"#),
            (.providerActivity(callerWorktree: "/r", runtime: .codex, sessionID: "sess", paneSessionName: "s", activity: .idle),
             #"{"caller_worktree":"/r","pane_session_name":"s","provider_sleep_activity":"idle","runtime":"codex","session_id":"sess","type":"provider_activity"}"#),
            (.attentionReport(callerWorktree: "/r", callerAgentID: "codex-1", recap: recap),
             #"{"caller_agent_id":"codex-1","caller_worktree":"/r","recap":{"checkpoint":"Green","completed":"Tests pass","context":"Login","decisions":["JWT"],"emoji":"e1","emojiAlternatives":["e2"],"need":"Review","next":"Open PR","purposeChanged":true,"title":"Fix auth"},"type":"attention_report"}"#),
            (.teamInbox(TeamInboxPageRequest(
                callerWorktree: "/r", callerAgentID: "codex-1", consuming: true, worktree: "w", repo: "/r", member: "m",
                unread: true, all: false, beforeID: "b", afterID: "a", snapshotThroughID: "s", forwardPagination: true,
                limit: 20)),
             #"{"after_id":"a","all":false,"before_id":"b","caller_agent_id":"codex-1","caller_worktree":"/r","consuming":true,"forward_pagination":true,"limit":20,"member":"m","repo":"/r","snapshot_through_id":"s","type":"team_inbox","unread":true,"worktree":"w"}"#),
            (.teamInboxAdvance(callerWorktree: "/r", callerAgentID: "codex-1", throughID: "0009"),
             #"{"caller_agent_id":"codex-1","caller_worktree":"/r","through_id":"0009","type":"team_inbox_advance"}"#),
            (.teamMembers(callerWorktree: "/r", worktree: "w", repo: "/r"),
             #"{"caller_worktree":"/r","repo":"/r","type":"team_members","worktree":"w"}"#),
            (.teamList(callerWorktree: "/r"), #"{"caller_worktree":"/r","type":"team_list"}"#),
            (.createWorktree(callerWorktree: "/r", worktreeName: "wt", branchName: "br", existing: false, base: "main",
                             command: "codex", agentRuntime: .codex, agentPrompt: "go", operationID: "op"),
             #"{"agent_prompt":"go","agent_runtime":"codex","base":"main","branch_name":"br","caller_worktree":"/r","command":"codex","existing":false,"operation_id":"op","type":"create_worktree","worktree_name":"wt"}"#),
            (.capabilities, #"{"type":"capabilities"}"#),
            (.agentPromptStagingCapability, #"{"type":"agent_prompt_staging_capability"}"#),
            (.worktreeBaseCapability, #"{"type":"worktree_base_capability"}"#),
            (.worktreeCreateIdempotencyCapability, #"{"type":"worktree_create_idempotency_capability"}"#),
            (.remoteWorktreeCapability, #"{"type":"remote_worktree_capability"}"#),
            (.worktreeCreateStatus(operationID: "op"), #"{"operation_id":"op","type":"worktree_create_status"}"#),
            (.removeWorktree(worktreePath: "/r/wt", force: true, pinned: false),
             #"{"force":true,"pinned":false,"type":"remove_worktree","worktree_path":"/r/wt"}"#),
            (.worktreeRemoveCapability, #"{"type":"worktree_remove_capability"}"#),
            (.worktreePinnedRemovalCapability, #"{"type":"worktree_pinned_removal_capability"}"#),
            (.worktreePinCapability, #"{"type":"worktree_pin_capability"}"#),
            (.setWorktreePinned(worktreePath: "/r/wt", isPinned: true),
             #"{"is_pinned":true,"type":"set_worktree_pinned","worktree_path":"/r/wt"}"#),
            (.worktreeRemoveStatus(operationID: "op"), #"{"operation_id":"op","type":"worktree_remove_status"}"#),
        ]
    }

    static func responses() throws -> [(ResponseMessage, String)] {
        [
            (.mcpConnections([]), #"{"mcpConnections":[],"type":"mcp_connections"}"#),
            (.remoteHosts([]),
             #"{"hosts":[],"type":"remote_hosts"}"#),
            (.agentSkills(skillStatus),
             #"{"agentSkills":{"descriptor":{"byteCount":12,"operationID":"00000000-0000-0000-0000-000000000001","repositoryID":"/repo","revision":"rev","runtime":"codex"},"phase":"staged","receivedBytes":12},"type":"agent_skills"}"#),
            (.placement(try placement()),
             #"{"placement":{"admittedAt":-978307200,"intent":{"branchName":"wt","demand":{"architecture":"arm64","cpus":1,"diskBytes":2048,"memoryBytes":1024},"repositoryID":"/repo","worktreeName":"wt"},"operationID":"00000000-0000-0000-0000-000000000001","owner":{"deviceID":{"value":"worker"},"fingerprint":{"rawBytes":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="}},"state":"preparing"},"type":"placement"}"#),
            (.linuxSetupIdentity(trust),
             #"{"identity":{"deviceID":"dev","displayName":"Mac","publicKey":"key"},"type":"linux_setup_identity"}"#),
            (.ok, #"{"type":"ok"}"#),
            (.error("boom"), #"{"message":"boom","type":"error"}"#),
            (.serverBusy,
             #"{"code":"graftty.control-socket.busy.v1","message":"Control socket is busy; retry the command.","type":"error"}"#),
            (.paneList([PaneInfo(id: 1, title: "zsh", focused: true)]),
             #"{"panes":[{"focused":true,"id":1,"title":"zsh"}],"type":"pane_list"}"#),
            (.paneShow("out"), #"{"text":"out","type":"pane_show"}"#),
            (.teamList(teamName: "t", members: [member]),
             #"{"members":[{"agents":[],"branch":"main","is_main_worktree":true,"is_running":false,"name":"main","worktree_path":"/r"}],"team_name":"t","type":"team_list"}"#),
            (.teamList(teamName: "t", members: [memberWithAgent]),
             #"{"members":[{"agents":[{"address":"/r/wt#codex-1","display_name":"Codex","id":"codex-1","is_reachable":true,"pane_session_name":"s","runtime":"codex"}],"branch":"wt","is_main_worktree":false,"is_running":true,"name":"wt","project_name":"app","project_path":"/r","worktree_path":"/r/wt"}],"team_name":"t","type":"team_list"}"#),
            (.mcpProxy(.accepted), #"{"mcpProxy":{"accepted":{}},"type":"mcp_proxy"}"#),
            (.teamHookOutput("{}"), #"{"output":"{}","type":"team_hook_output"}"#),
            (.teamInbox(messages: [inboxMessage], nextBeforeID: "b", nextAfterID: "a", snapshotThroughID: "s"),
             #"{"messages":[{"agent_prompt":"prompt","batch_id":"batch","body":"hi","created_at":-978307200,"from":{"agentID":"codex-1","member":"a","runtime":"codex","worktree":"/r/a"},"id":"0001","kind":"team_message","priority":"normal","repo_path":"/r","source":"github","team":"t","to":{"member":"b","worktree":"/r/b"}}],"next_after_id":"a","next_before_id":"b","snapshot_through_id":"s","type":"team_inbox"}"#),
            (.worktreeCreate(createStatus),
             #"{"operation":{"error":"boom","message_address":"/r/wt","operation_id":"op","state":"failed","worktree_path":"/r/wt"},"type":"worktree_create"}"#),
            (.capabilities(["worktree_base", "pane_agent"]),
             #"{"capabilities":["worktree_base","pane_agent"],"type":"capabilities"}"#),
            (.worktreeCreateRetry(operationID: "op"), #"{"operation_id":"op","type":"worktree_create_retry"}"#),
            (.worktreeRemove(removeStatus),
             #"{"operation":{"error":"dirty","force_allowed":true,"operation_id":"op","short_status":"M a","state":"failed","worktree_path":"/r/wt"},"type":"worktree_remove"}"#),
        ]
    }

    /// Exhaustive on purpose: a new case fails to compile here, which sends
    /// its author to add a fixture above. The switch cannot see the lists, so
    /// keep at least one encoding fixture per case.
    static func fixtureCoverage(_ request: NotificationMessage, _ response: ResponseMessage) {
        switch request {
        case .addProject, .projectAddCapability, .linuxSetupIdentity, .completeLinuxSetup, .previewFiles, .previewImage, .offerResource, .notify, .clear,
             .listPanes, .reconnectRemoteMac, .reconnectRemoteClient, .remoteWorktree, .addPane, .paneAgentCapability,
             .closePane, .showPane, .sendPane, .teamSend, .teamReply, .teamBroadcast, .teamHook,
             .providerActivity, .attentionReport, .teamInbox, .teamInboxAdvance, .teamMembers, .teamList,
             .createWorktree, .agentPromptStagingCapability, .worktreeBaseCapability,
             .worktreeCreateIdempotencyCapability, .remoteWorktreeCapability, .worktreeCreateStatus, .removeWorktree,
             .worktreeRemoveCapability, .worktreePinnedRemovalCapability, .worktreePinCapability, .setWorktreePinned,
             .worktreeRemoveStatus, .capabilities, .mcpConnection, .mcpBridge, .remoteSkills, .remotePlacement, .listRemoteHosts: break
        }
        switch response {
        case .linuxSetupIdentity, .ok, .error, .serverBusy, .paneList, .paneShow, .teamList, .teamHookOutput,
             .teamInbox, .worktreeCreate, .worktreeCreateRetry, .worktreeRemove, .capabilities, .mcpConnections, .mcpProxy, .agentSkills, .placement, .remoteHosts: break
        }
    }

    @Test func requestsEncodeToFrozenJSON() throws {
        for (message, frozen) in try Self.requests() {
            #expect(try Self.json(message) == frozen)
        }
    }

    @Test func frozenRequestJSONDecodes() throws {
        for (message, frozen) in try Self.requests() {
            #expect(try JSONDecoder().decode(NotificationMessage.self, from: Data(frozen.utf8)) == message)
        }
    }

    @Test func responsesEncodeToFrozenJSON() throws {
        for (response, frozen) in try Self.responses() {
            #expect(try Self.json(response) == frozen)
        }
    }

    @Test func frozenResponseJSONDecodes() throws {
        for (response, frozen) in try Self.responses() {
            #expect(try JSONDecoder().decode(ResponseMessage.self, from: Data(frozen.utf8)) == response)
        }
    }

    /// Fields added after a request first shipped are absent from older
    /// peers' JSON and must keep their historical defaults.
    @Test func olderRequestsWithoutLaterFieldsDecode() throws {
        let cases: [(String, NotificationMessage)] = [
            (#"{"type":"preview_files","path":"/r","targets":["a.md"]}"#,
             .previewFiles(path: "/r", targets: ["a.md"])),
            (#"{"type":"preview_image","path":"/r","target":"a.png"}"#, .previewImage(path: "/r", target: "a.png")),
            (#"{"type":"open_resource","path":"/r","target":"a.pdf"}"#, .offerResource(path: "/r", target: "a.pdf")),
            (#"{"type":"notify","path":"/r","text":"hi"}"#, .notify(path: "/r", text: "hi")),
            (#"{"type":"clear","path":"/r"}"#, .clear(path: "/r")),
            (#"{"type":"team_message","caller_worktree":"/r","recipient":"b","text":"hi"}"#,
             .teamSend(callerWorktree: "/r", recipient: "b", text: "hi", priority: .normal)),
            (#"{"type":"team_broadcast","caller_worktree":"/r","text":"hi","priority":"normal"}"#,
             .teamBroadcast(callerWorktree: "/r", text: "hi", priority: .normal)),
            (#"{"type":"team_inbox_advance","caller_worktree":"/r","through_id":"0009"}"#,
             .teamInboxAdvance(callerWorktree: "/r", throughID: "0009")),
            (#"{"type":"team_send","caller_worktree":"/r","recipient":"b","text":"hi","priority":"normal"}"#,
             .teamSend(callerWorktree: "/r", recipient: "b", text: "hi", priority: .normal)),
            (#"{"type":"team_reply","caller_worktree":"/r","message_id":"1","text":"ok","priority":"normal"}"#,
             .teamReply(callerWorktree: "/r", messageID: "1", text: "ok", priority: .normal, fallback: false)),
            (#"{"type":"team_hook","caller_worktree":"/r","runtime":"codex","event":"stop"}"#,
             .teamHook(callerWorktree: "/r", callerAgentID: nil, runtime: .codex, event: .stop, sessionID: nil,
                       paneSessionName: nil, attentionReason: nil, stopHookActive: false, providerSleepActivity: nil)),
            (#"{"type":"provider_activity","caller_worktree":"/r","runtime":"codex"}"#,
             .providerActivity(callerWorktree: "/r", runtime: .codex, sessionID: nil, paneSessionName: nil,
                               activity: .unknown)),
            // A newer peer's unrecognized activity must also stay awake.
            (#"{"type":"provider_activity","caller_worktree":"/r","runtime":"codex","provider_sleep_activity":"napping"}"#,
             .providerActivity(callerWorktree: "/r", runtime: .codex, sessionID: nil, paneSessionName: nil,
                               activity: .unknown)),
            (#"{"type":"team_inbox","unread":true,"all":false}"#,
             .teamInbox(TeamInboxPageRequest(callerWorktree: nil, callerAgentID: nil, consuming: false, worktree: nil, repo: nil, member: nil, unread: true,
                                             all: false, beforeID: nil, afterID: nil, snapshotThroughID: nil,
                                             forwardPagination: nil, limit: nil))),
            (#"{"type":"attention_report","caller_worktree":"/r","caller_agent_id":"codex-1","recap":{"title":"t","completed":"c","next":"n"}}"#,
             .attentionReport(callerWorktree: "/r", callerAgentID: "codex-1",
                              recap: AttentionRecap(title: "t", context: nil, completed: "c", next: "n", need: nil,
                                                    emoji: nil, emojiAlternatives: nil, purposeChanged: nil,
                                                    checkpoint: nil, decisions: nil))),
            (#"{"type":"team_members"}"#, .teamMembers(callerWorktree: nil, worktree: nil, repo: nil)),
            (#"{"type":"add_pane","path":"/r","direction":"right"}"#,
             .addPane(path: "/r", direction: .right, command: nil)),
            (#"{"type":"create_worktree","caller_worktree":"/r","worktree_name":"wt","branch_name":"wt","existing":true}"#,
             .createWorktree(callerWorktree: "/r", worktreeName: "wt", branchName: "wt", existing: true, base: nil,
                             command: nil, agentRuntime: nil, agentPrompt: nil, operationID: nil)),
            (#"{"type":"remove_worktree","worktree_path":"/r/wt","force":false}"#,
             .removeWorktree(worktreePath: "/r/wt", force: false, pinned: false)),
        ]
        for (json, expected) in cases {
            #expect(try JSONDecoder().decode(NotificationMessage.self, from: Data(json.utf8)) == expected)
        }
    }

    @Test func olderResponsesDecode() throws {
        let legacyMember = #"{"name":"main","branch":"main","worktree_path":"/r","role":"lead","is_running":false}"#
        let legacyCoworker = #"{"name":"wt","branch":"wt","worktree_path":"/r/wt","role":"coworker","is_running":true}"#
        let minimalMessage = #"{"id":"0001","created_at":0,"team":"t","repo_path":"/r","from":{"member":"a","worktree":"/r/a"},"to":{"member":"b","worktree":"/r/b"},"priority":"normal","kind":"team_message","body":"hi"}"#
        let cases: [(String, ResponseMessage)] = [
            (#"{"type":"team_list","team_name":"t","members":[\#(legacyCoworker)]}"#,
             .teamList(teamName: "t", members: [TeamListMember(
                name: "wt", branch: "wt", worktreePath: "/r/wt", isMainWorktree: false, isRunning: true,
                agents: [], projectPath: nil, projectName: nil)])),
            (#"{"type":"team_inbox","messages":[\#(minimalMessage)]}"#,
             .teamInbox(messages: [TeamInboxMessage(
                id: "0001", batchID: nil, createdAt: Date(timeIntervalSinceReferenceDate: 0), team: "t", repoPath: "/r",
                from: .init(member: "a", worktree: "/r/a", runtime: nil), to: .init(member: "b", worktree: "/r/b", runtime: nil),
                priority: .normal, body: "hi", agentPrompt: nil, source: nil)],
                nextBeforeID: nil, nextAfterID: nil, snapshotThroughID: nil)),
            (#"{"type":"pane_list","panes":[{"id":2,"focused":false}]}"#,
             .paneList([PaneInfo(id: 2, title: nil, focused: false)])),
            (#"{"type":"worktree_create","operation":{"operation_id":"op","state":"ready","worktree_path":"/r/wt","message_address":"/r/wt"}}"#,
             .worktreeCreate(WorktreeCreateStatus(operationID: "op", state: .ready, worktreePath: "/r/wt",
                                                  messageAddress: "/r/wt", error: nil))),
            (#"{"type":"worktree_remove","operation":{"operation_id":"op","state":"removed","worktree_path":"/r/wt","force_allowed":false}}"#,
             .worktreeRemove(WorktreeRemoveStatus(operationID: "op", state: .removed, worktreePath: "/r/wt",
                                                  error: nil, forceAllowed: false, shortStatus: nil))),
            // Servers before the structured busy code put it in `message`.
            (#"{"type":"error","message":"graftty.control-socket.busy.v1"}"#, .serverBusy),
            (#"{"type":"team_list","team_name":"t","members":[\#(legacyMember)]}"#,
             .teamList(teamName: "t", members: [Self.member])),
            (#"{"type":"team_inbox","messages":[]}"#,
             .teamInbox(messages: [], nextBeforeID: nil, nextAfterID: nil, snapshotThroughID: nil)),
        ]
        for (json, expected) in cases {
            #expect(try JSONDecoder().decode(ResponseMessage.self, from: Data(json.utf8)) == expected)
        }
    }

    /// Enum values are wire spellings too: an older peer rejects a renamed
    /// raw value the same way it rejects a renamed key.
    @Test func enumWireValuesStayFrozen() {
        #expect(TeamHookRuntime.allCases.map(\.rawValue) == ["codex", "claude"])
        #expect(ControlCapability.allCases.map(\.rawValue) == [
            "agent_prompt_staging", "pane_agent", "worktree_base", "worktree_create_idempotency", "remote_worktree",
            "worktree_remove", "worktree_pinned_removal", "worktree_pin", "project_add",
        ])
        #expect(TeamHookEvent.allCases.map(\.rawValue) == [
            "session-start", "user-prompt-submit", "pre-tool-use", "post-tool-use", "post-tool-use-failure",
            "permission-request", "stop",
        ])
        #expect(LinuxHostComponent.allCases.map(\.rawValue) == ["graftty", "codex", "claude"])
        #expect([PaneSplit.right, .left, .up, .down].map(\.rawValue) == ["right", "left", "up", "down"])
        #expect([TeamInboxPriority.normal, .urgent].map(\.rawValue) == ["normal", "urgent"])
        #expect([AgentHookAttentionReason.permission, .question, .planReview].map(\.rawValue)
                == ["permission", "question", "plan_review"])
        #expect([ProviderSleepActivity.unknown, .busy, .idle].map(\.rawValue) == ["unknown", "busy", "idle"])
        #expect([WorktreeCreateState.pending, .ready, .failed].map(\.rawValue) == ["pending", "ready", "failed"])
        #expect([WorktreeRemoveState.pending, .removed, .failed].map(\.rawValue) == ["pending", "removed", "failed"])
        #expect([LinuxHostComponentOutcome.Status.succeeded, .failed, .unknown, .skipped].map(\.rawValue)
                == ["succeeded", "failed", "unknown", "skipped"])
    }
}
