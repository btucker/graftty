import Foundation
import GrafttyProtocol

/// The control-socket dispatcher shared by the Mac app and the headless
/// host. It owns attention, recap, and team messages; every other request
/// goes to `ControlPlatform.handlePlatformRequest`.
@MainActor
public enum ControlRequestCore {
    /// Fire-and-forget path. Returns false for messages that expect a
    /// response; those are answered by `handleRequest`.
    @discardableResult
    public static func handleMessage(_ message: NotificationMessage, platform: any ControlPlatform) -> Bool {
        switch message {
        case let .providerActivity(path, runtime, sessionID, paneSessionName, activity):
            platform.providerActivity(path: path, paneSessionName: paneSessionName, sessionID: sessionID,
                                      activity: activity, runtime: runtime)
        case .notify(let path, let text, let clearAfter, let paneSessionName):
            let autoClear = platform.state.applyUserNotify(path: path, text: text, clearAfter: clearAfter,
                                                              paneSessionName: paneSessionName)
            try? platform.stateDidChange()
            if let autoClear {
                Task { @MainActor [weak platform] in
                    try? await Task.sleep(for: .seconds(autoClear.delay))
                    guard let platform else { return }
                    platform.state.applyAutoClear(autoClear)
                    try? platform.stateDidChange()
                }
            }
        case .clear(let path, let paneSessionName):
            platform.state.applyUserClear(path: path, paneSessionName: paneSessionName)
            try? platform.stateDidChange()
        default:
            return false
        }
        return true
    }

    /// Request/response path. Fire-and-forget messages answer nil here
    /// without applying anything; `handleMessage` applies them.
    public static func handleRequest(_ message: NotificationMessage, platform: any ControlPlatform) async -> ResponseMessage? {
        switch message {
        case .notify, .clear, .providerActivity:
            return nil
        case .attentionReport(let callerPath, let callerAgentID, let recap):
            guard recap.isValid, platform.state.worktree(forPath: callerPath) != nil else {
                return .error("invalid attention recap or unknown worktree")
            }
            platform.attentionRecaps.report(recap, worktree: callerPath, agentID: callerAgentID)
            return .ok
        case .teamSend(let callerPath, let callerAgentID, let recipient, let text, let priority):
            return await teamSend(callerPath: callerPath, callerAgentID: callerAgentID, recipient: recipient,
                                  text: text, priority: priority, platform: platform)
        case .teamMessage(let callerPath, let recipient, let text):
            return await teamSend(callerPath: callerPath, callerAgentID: nil, recipient: recipient,
                                  text: text, priority: .normal, platform: platform)
        case .teamReply:
            return await teamReply(message, platform: platform)
        case .teamBroadcast(let callerPath, let callerAgentID, let text, let priority):
            return await teamInboxOperation("failed to write team inbox broadcast", platform: platform) { handler, repos, enabled in
                _ = try handler.broadcast(callerWorktree: callerPath, callerAgentID: callerAgentID, text: text,
                                          priority: priority, repos: repos, teamsEnabled: enabled)
                return .ok
            }
        case .teamInbox(let request):
            // ATTN-2.19: the inbox page parses the full message history off the main actor.
            return await teamInboxOperation("failed to read team inbox", platform: platform) { handler, repos, enabled in
                let page = try handler.diagnosticPage(
                    callerWorktree: request.callerWorktree, callerAgentID: request.callerAgentID,
                    consuming: request.consuming, worktree: request.worktree, repo: request.repo,
                    member: request.member, unread: request.unread, all: request.all,
                    beforeID: request.beforeID, afterID: request.afterID,
                    snapshotThroughID: request.snapshotThroughID, forwardPagination: request.forwardPagination,
                    limit: request.limit, repos: repos, teamsEnabled: enabled
                )
                return .teamInbox(messages: page.messages, nextBeforeID: page.nextBeforeID,
                                  nextAfterID: page.nextAfterID, snapshotThroughID: page.snapshotThroughID)
            }
        case .teamInboxAdvance(let callerPath, let callerAgentID, let throughID):
            return await teamInboxOperation("failed to advance team inbox", platform: platform, reportsInboxErrors: true) { handler, repos, enabled in
                try handler.advanceRead(callerWorktree: callerPath, callerAgentID: callerAgentID,
                                        throughID: throughID, repos: repos, teamsEnabled: enabled)
                return .ok
            }
        case .teamMembers(let callerPath, let worktree, let repo):
            return teamMembers(callerPath: callerPath, worktree: worktree, repo: repo, platform: platform)
        case .teamList(let callerPath):
            return teamMembers(callerPath: callerPath, worktree: nil, repo: nil, platform: platform)
        case let .teamHook(callerPath, callerAgentID, runtime, event, sessionID, paneSessionName,
                           attentionReason, stopHookActive, providerSleepActivity):
            platform.providerActivity(path: callerPath, paneSessionName: paneSessionName, sessionID: sessionID,
                                      activity: providerSleepActivity ?? .unknown, runtime: runtime)
            return await teamHook(callerPath: callerPath, callerAgentID: callerAgentID, runtime: runtime,
                                  event: event, sessionID: sessionID, paneSessionName: paneSessionName,
                                  attentionReason: attentionReason, stopHookActive: stopHookActive, platform: platform)
        case .listPanes, .addPane, .closePane, .showPane, .sendPane,
             .previewFiles, .previewImage, .offerResource,
             .createWorktree, .worktreeCreateStatus, .removeWorktree, .worktreeRemoveStatus, .setWorktreePinned,
             .agentPromptStagingCapability, .paneAgentCapability, .worktreeBaseCapability, .worktreeCreateIdempotencyCapability,
             .remoteWorktreeCapability, .worktreeRemoveCapability, .worktreePinnedRemovalCapability,
             .worktreePinCapability,
             .remoteWorktree, .reconnectRemoteMac, .reconnectRemoteClient,
             .linuxSetupIdentity, .completeLinuxSetup:
            return await platform.handlePlatformRequest(message)
        }
    }

    /// Hooks that exist only to carry attention signals. Codex PostToolUse
    /// belongs here too: Codex has no PostToolUse context channel, so the
    /// team handler would only ever render `{}` for it after scanning
    /// presence on every tool call.
    public nonisolated static func isAttentionOnlyTeamHook(runtime: TeamHookRuntime, event: TeamHookEvent) -> Bool {
        switch event {
        case .preToolUse, .permissionRequest, .userPromptSubmit, .postToolUseFailure:
            return true
        case .postToolUse:
            return runtime == .codex
        case .sessionStart, .stop:
            return false
        }
    }

    /// Publishes provider hook busy/idle state, but only for a pane tracked
    /// in the caller's worktree.
    public static func recordHookLiveness(callerPath: String, runtime: TeamHookRuntime, event: TeamHookEvent,
                                          sessionID: String?, paneSessionName: String?,
                                          attentionReason: AgentHookAttentionReason?, platform: any ControlPlatform) {
        guard let paneSessionName,
              platform.state.worktree(forPath: callerPath)?.paneSlot(forSessionName: paneSessionName) != nil else { return }
        platform.recordHookLiveness(runtime: runtime, event: event, sessionID: sessionID,
                                    paneSessionName: paneSessionName, attentionReason: attentionReason)
    }

    /// Records a stopped turn and posts its notification through the platform.
    public static func recordStoppedTurn(callerPath: String, runtime: TeamHookRuntime, callerAgentID: String?,
                                         sessionID: String?, paneSessionName: String?, recap: AttentionRecap?,
                                         stoppedAt: Date, platform: any ControlPlatform) {
        if let notification = platform.state.recordStoppedTurn(
            callerPath: callerPath, runtime: runtime, callerAgentID: callerAgentID, sessionID: sessionID,
            paneSessionName: paneSessionName, recap: recap, stoppedAt: stoppedAt,
            paneTitle: { platform.paneTitle(for: $0, in: $1) }
        ) {
            platform.postAgentNotification(notification, worktreePath: callerPath)
        }
    }

    // MARK: - Team messages

    private static func teamHandler(platform: any ControlTeamPlatform,
                                    policy: TeamHookDeliveryPolicy = TeamHookDeliveryPolicy()) -> TeamInboxRequestHandler {
        let presence = platform.teamPresence
        return TeamInboxRequestHandler(
            inbox: platform.teamInbox,
            dispatcher: platform.teamEventDispatcher,
            automaticDeliveryOwner: policy.automaticDeliveryOwner,
            agentRecords: { (try? presence.listAll()) ?? [] },
            agentReachability: policy.agentReachability
        )
    }

    /// ATTN-2.19: snapshots main-actor state, then runs the file-backed
    /// inbox work off the main actor so inbox contention cannot wedge the
    /// control socket.
    private static func teamInboxOperation(
        _ failure: String, platform: any ControlTeamPlatform, reportsInboxErrors: Bool = false,
        _ body: @escaping @Sendable (TeamInboxRequestHandler, [RepoEntry], Bool) throws -> ResponseMessage
    ) async -> ResponseMessage {
        let handler = teamHandler(platform: platform)
        let repos = platform.state.repos
        let enabled = platform.teamsEnabled
        do {
            return try await OffMainIO.run { try body(handler, repos, enabled) }
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch let error as TeamInboxError where reportsInboxErrors {
            return .error(error.description)
        } catch {
            return .error("\(failure): \(error)")
        }
    }

    /// Sends to a paired Mac when the recipient is a `graftty-mac:` address,
    /// otherwise appends to the local team inbox.
    private static func teamSend(callerPath: String, callerAgentID: String?, recipient: String, text: String,
                                 priority: TeamInboxPriority, platform: any ControlTeamPlatform) async -> ResponseMessage {
        guard recipient.hasPrefix("graftty-mac:") else {
            return await teamInboxOperation("failed to write team inbox message", platform: platform) { handler, repos, enabled in
                _ = try handler.send(callerWorktree: callerPath, callerAgentID: callerAgentID, recipient: recipient,
                                     text: text, priority: priority, repos: repos, teamsEnabled: enabled)
                return .ok
            }
        }
        guard platform.teamsEnabled else { return .error(TeamInboxRequestError.teamModeDisabled.description) }
        guard platform.state.worktree(forPath: callerPath) != nil else {
            return .error(TeamInboxRequestError.callerNotTracked.description)
        }
        guard let routing = platform.remoteTeamRouting else { return .error("remote team connection is unavailable") }
        return await routing.send(callerWorktree: callerPath, callerAgentID: callerAgentID, recipient: recipient,
                                  text: text, priority: priority)
    }

    /// Resolves a reply to its stored sender, then sends it locally or to a paired Mac.
    public static func teamReply(_ message: NotificationMessage, platform: any ControlTeamPlatform) async -> ResponseMessage {
        guard case .teamReply(let caller, let agent, let id, let text, let priority, let fallback) = message else {
            return .error("Expected a team reply")
        }
        let inbox = platform.teamInbox
        let repos = platform.state.repos
        let enabled = platform.teamsEnabled
        do {
            let request = try await OffMainIO.run {
                try TeamReplyResolver(inbox: inbox).resolve(
                    callerWorktree: caller, callerAgentID: agent, messageID: id,
                    fallback: fallback, text: text, priority: priority,
                    repos: repos, teamsEnabled: enabled
                )
            }
            guard case .teamSend(_, _, let recipient, _, _) = request else {
                return .error("Invalid reply destination")
            }
            return await teamSend(callerPath: caller, callerAgentID: agent, recipient: recipient,
                                  text: text, priority: priority, platform: platform)
        } catch {
            return .error(String(describing: error))
        }
    }

    private static func teamMembers(callerPath: String?, worktree: String?, repo: String?,
                                    platform: any ControlTeamPlatform) -> ResponseMessage {
        do {
            let result = try teamHandler(platform: platform).members(
                callerWorktree: callerPath, worktree: worktree, repo: repo,
                repos: platform.state.repos, teamsEnabled: platform.teamsEnabled
            )
            return .teamList(teamName: result.teamName, members: result.members)
        } catch let error as TeamInboxRequestError {
            return .error(error.description)
        } catch {
            return .error("failed to list team members: \(error)")
        }
    }

    // MARK: - Team hooks

    private static func teamHook(callerPath: String, callerAgentID: String?, runtime: TeamHookRuntime,
                                 event: TeamHookEvent, sessionID: String?, paneSessionName: String?,
                                 attentionReason: AgentHookAttentionReason?, stopHookActive: Bool,
                                 platform: any ControlPlatform) async -> ResponseMessage {
        recordHookLiveness(callerPath: callerPath, runtime: runtime, event: event, sessionID: sessionID ?? callerAgentID,
                           paneSessionName: paneSessionName, attentionReason: attentionReason, platform: platform)
        let action = AgentHookAttentionTransition.action(event: event, reason: attentionReason)
        switch action {
        case .recordStoppedTurn:
            switch platform.attentionRecaps.stop(worktree: callerPath, agentID: callerAgentID,
                                                 stopHookActive: stopHookActive) {
            case .requestRecap:
                return .teamHookOutput(TeamHookRenderer.requestRecap())
            case .record(let recap):
                recordStoppedTurn(callerPath: callerPath, runtime: runtime, callerAgentID: callerAgentID,
                                  sessionID: sessionID, paneSessionName: paneSessionName, recap: recap,
                                  stoppedAt: Date(), platform: platform)
            }
        case .record(let reason):
            if let notification = platform.state.recordAgentAttention(
                callerPath: callerPath, callerAgentID: callerAgentID, runtime: runtime, reason: reason,
                sessionID: sessionID, paneSessionName: paneSessionName
            ) {
                platform.postAgentNotification(notification, worktreePath: callerPath)
            }
        case .clear:
            platform.state.clearAgentAttention(callerPath: callerPath, callerAgentID: callerAgentID,
                                                  runtime: runtime, sessionID: sessionID)
        case .none:
            break
        }
        // A `.none` transition (PreToolUse, PermissionRequest) leaves state
        // untouched, so the headless host skips a state write per tool call.
        if action != AgentHookAttentionAction.none {
            do { try platform.stateDidChange() } catch { return .error(String(describing: error)) }
        }

        // Attention-only hooks must return quickly and must not depend on the
        // team feature being enabled. They carry no inbox or instruction data.
        if isAttentionOnlyTeamHook(runtime: runtime, event: event) {
            return .teamHookOutput("{}")
        }

        do {
            let teamsEnabled = platform.teamsEnabled
            if event == .sessionStart, !teamsEnabled {
                return .teamHookOutput(try TeamHookRenderer.sessionStart(runtime: runtime))
            }
            // Snapshotted before the instruction render's `await`; the
            // ownership decision below therefore reads presence as it stood
            // at hook entry. A stale snapshot at worst hands delivery to a
            // pane that has just gone away.
            // ATTN-2.19: the presence read is file I/O, so it runs off the
            // main actor like the inbox work below.
            let presence = platform.teamPresence
            let presenceRecords = await OffMainIO.run { (try? presence.listAll()) ?? [] }
            let repos = platform.state.repos
            // The wrapper-launched CLI knows its own canonical identity
            // (GRAFTTY_AGENT_ID / pane presence), so a caller-supplied agent
            // ID wins; the session-based resolver covers older CLIs, and the
            // handler's hash fallback remains behind both.
            let currentAgentID = callerAgentID
                ?? TeamLookup.team(for: callerPath, in: repos).flatMap { team in
                    TeamAgentSessionIdentityResolver.agentID(
                        records: presenceRecords, teamID: TeamLookup.id(of: team), worktree: callerPath,
                        runtime: runtime, sessionID: sessionID, paneSessionName: paneSessionName
                    )
                }
            let policy = platform.hookDeliveryPolicy(presence: presenceRecords)
            var instructions = ""
            if event == .sessionStart,
               let team = TeamLookup.team(for: callerPath, in: platform.state.repos),
               let viewer = team.members.first(where: { $0.worktreePath == callerPath }) {
                instructions = await InstructionSessionText.render(
                    team: team,
                    viewer: viewer,
                    defaultBranch: platform.instructionsDefaultBranch(
                        repoPath: team.repoPath,
                        hint: platform.state.repo(forWorktreePath: callerPath)?.defaultBranchHint
                    ),
                    applicationSupportDirectory: platform.instructionsDirectory
                )
            }
            let handler = teamHandler(platform: platform, policy: policy)
            // ATTN-2.19: hook delivery parses the full inbox history and
            // can wait on the inter-process watermark lock; it fires on
            // every PostToolUse of every agent, so on the main actor it
            // wedged the control socket under agent activity.
            let output = try await OffMainIO.run { [instructions] in
                try handler.hook(
                    callerWorktree: callerPath, runtime: runtime, event: event, sessionID: sessionID,
                    paneSessionName: paneSessionName, repos: repos, teamsEnabled: teamsEnabled,
                    instructions: instructions, agentID: currentAgentID
                )
            }
            return .teamHookOutput(output)
        } catch let error as TeamInboxRequestError {
            // The CLI decides whether an unrendered SessionStart still gets
            // skill guidance (AGENT-6.49): only inside a Graftty terminal.
            return .error(error.description)
        } catch {
            return .error("failed to render team hook context: \(error)")
        }
    }
}
