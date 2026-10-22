import ArgumentParser
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import GrafttyKit

struct Team: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coordinate with teammates in a Graftty agent team",
        subcommands: [
            TeamSend.self,
            TeamReply.self,
            TeamBroadcast.self,
            TeamMembers.self,
            TeamHook.self,
            TeamInbox.self,
            TeamMsg.self,
            TeamList.self,
            TeamRegister.self,
            TeamUnregister.self,
            TeamCodexAppServer.self,
            TeamWatchInbox.self,
        ]
    )
}

struct TeamSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to a worktree, provider, or exact canonical agent"
    )

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent: Bool = false

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Local worktree name/path or a local or remote agent address from team list --json")
    var address: String

    @Argument(help: "Message text")
    var text: String?

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let body = try TeamMessageInput.resolve(text: text, stdin: stdin)
        let response = try CLIEnv.sendRequest(
            .teamSend(
                callerWorktree: worktreePath,
                callerAgentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath),
                recipient: address,
                text: body,
                priority: urgent ? .urgent : .normal
            )
        )
        try CLIEnv.expectOk(response, for: "team send")
    }
}

struct TeamReply: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reply",
        abstract: "Reply to a stored inbox message without looking up the sender's name"
    )

    @Argument(help: "Message ID from a delivered message or team inbox")
    var messageID: String

    @Argument(help: "Reply text")
    var text: String?

    @Flag(name: .long, help: "Read reply text from standard input")
    var stdin = false

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent = false

    @Flag(name: .long, help: "Queue for the original sender's provider on the same Mac instead of its exact agent")
    var fallback = false

    func run() throws {
        let worktree = try CLIEnv.resolveWorktree()
        try execute(
            callerWorktree: worktree,
            callerAgentID: TeamMessageInput.currentAgentID(worktreePath: worktree),
            body: TeamMessageInput.resolve(text: text, stdin: stdin),
            sendRequest: CLIEnv.sendRequest
        )
    }

    func execute(
        callerWorktree: String,
        callerAgentID: String?,
        body: String,
        sendRequest: (NotificationMessage) throws -> ResponseMessage
    ) throws {
        let response = try sendRequest(.teamReply(
            callerWorktree: callerWorktree,
            callerAgentID: callerAgentID,
            messageID: messageID,
            text: body,
            priority: urgent ? .urgent : .normal,
            fallback: fallback
        ))
        try CLIEnv.expectOk(response, for: "team reply")
    }
}

struct TeamBroadcast: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Send the same message to every other worktree in the local repository"
    )

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent: Bool = false

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Message text")
    var text: String?

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let body = try TeamMessageInput.resolve(text: text, stdin: stdin)
        let response = try CLIEnv.sendRequest(
            .teamBroadcast(
                callerWorktree: worktreePath,
                callerAgentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath),
                text: body,
                priority: urgent ? .urgent : .normal
            )
        )
        try CLIEnv.expectOk(response, for: "team broadcast")
    }
}

struct TeamMembers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "members",
        abstract: "List the members of a worktree's team"
    )

    @Option(name: .long, help: "Worktree path or member name to inspect")
    var worktree: String?

    @Option(name: .long, help: "Repository path to inspect")
    var repo: String?

    @Flag(name: .long, help: "Print stable JSON instead of human-formatted rows")
    var json: Bool = false

    func run() throws {
        let callerWorktree = try TeamDiagnosticScope.resolveCaller(worktree: worktree, repo: repo)
        let response = try CLIEnv.sendRequest(
            .teamMembers(callerWorktree: callerWorktree, worktree: worktree, repo: repo)
        )
        try TeamOutput.printMembers(response, json: json, command: "team members")
    }
}

struct TeamHook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Render agent-team hook context for an agent runtime"
    )

    @Argument(help: "Runtime: codex or claude")
    var runtime: String

    @Argument(help: "Hook event: session-start, user-prompt-submit, pre-tool-use, post-tool-use, post-tool-use-failure, permission-request, or stop")
    var event: String

    @Option(name: [.customLong("session-id"), .customLong("session")], help: "Stable runtime session identifier")
    var sessionID: String?

    /// AGENT-6.48: the provider plugins pass this flag; hooks from sessions
    /// launched by an older Graftty omit it. Both are handled identically.
    @Flag(name: .customLong("skill-managed"), help: .hidden)
    var skillManaged = false

    func validate() throws {
        guard TeamHookRuntime(rawValue: runtime) != nil else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        guard TeamHookEvent(rawValue: event) != nil else {
            throw ValidationError(
                "event must be one of: session-start, user-prompt-submit, pre-tool-use, post-tool-use, post-tool-use-failure, permission-request, stop"
            )
        }
    }

    func run() throws {
        // Drain the hook event JSON the runtime writes to our stdin
        // BEFORE doing anything else. If we exit without consuming it,
        // the runtime's write syscall hits EPIPE and reports "failed to
        // write hook stdin: Broken pipe". The payload also carries
        // `session_id`, which we prefer over the env-var fallback.
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let stdinPayload = (try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]) ?? [:]
        let stdinSessionID = stdinPayload["session_id"] as? String
        let runtime = TeamHookRuntime(rawValue: runtime)!
        let event = TeamHookEvent(rawValue: event)!
        let attentionReason = AgentHookAttentionClassifier.reason(
            runtime: runtime,
            event: event,
            stdinJSON: stdinPayload
        )
        let stopHookActive = stdinPayload["stop_hook_active"] as? Bool ?? false

        // TEAM-9.1
        if event == .stop, AgentStopHookFilter.isSubagentStop(stdinJSON: stdinPayload) {
            print("{}")
            return
        }

        guard let worktreePath = try? WorktreeResolver.resolve() else {
            print("{}")
            return
        }
        let resolvedSessionID = sessionID
            ?? stdinSessionID
            ?? ProcessInfo.processInfo.environment["GRAFTTY_AGENT_SESSION_ID"]
        let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        )
        func stageAttentionProgress() {
            try? AttentionFileHandoff().progress(
                worktree: worktreePath,
                agentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath),
                runtime: runtime,
                sessionID: resolvedSessionID,
                userPrompt: event == .userPromptSubmit ? WorktreeUserPrompt.text(from: stdinPayload) : nil
            )
        }
        if event == .sessionStart || event == .userPromptSubmit {
            stageAttentionProgress()
        }
        if runtime == .claude,
           event == .sessionStart || event == .postToolUse || event == .stop,
           let resolvedSessionID {
            updateClaudeNativePresence(
                event: event,
                sessionID: resolvedSessionID,
                worktreePath: worktreePath,
                paneSessionName: paneSessionName
            )
        }
        if runtime == .codex,
           event == .sessionStart || event == .postToolUse,
           let resolvedSessionID {
            bindCodexNativeSession(
                event: event,
                sessionID: resolvedSessionID,
                worktreePath: worktreePath,
                paneSessionName: paneSessionName
            )
        }
        let providerSleepActivity: ProviderSleepActivity = runtime == .claude
            ? .claudeHook(payload: stdinPayload, event: event.camelCaseKey)
            : .unknown
        // Send before Attention's Stop handoff, which can return without a team hook.
        // This one-way message only supplies provider evidence; it does not change liveness.
        try? SocketClient.send(.providerActivity(
            callerWorktree: worktreePath,
            runtime: runtime,
            sessionID: resolvedSessionID,
            paneSessionName: paneSessionName,
            activity: providerSleepActivity
        ))
        if event == .stop,
           let action = try? AttentionFileHandoff().stop(
                worktree: worktreePath,
                agentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath)
                    ?? resolvedSessionID.map { TeamAgentIdentity(runtime: runtime, nativeSessionID: $0).rawValue },
                runtime: runtime,
                sessionID: resolvedSessionID,
                paneSessionName: paneSessionName,
                stopHookActive: stopHookActive,
                turnID: stdinPayload["turn_id"] as? String
           ) {
            print(action == .requestRecap ? TeamHookRenderer.requestRecap() : "{}")
            return
        }
        do {
            let response = try SocketClient.sendExpectingResponse(
                .teamHook(
                    callerWorktree: worktreePath,
                    callerAgentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath),
                    runtime: runtime,
                    event: event,
                    sessionID: resolvedSessionID,
                    paneSessionName: paneSessionName,
                    attentionReason: attentionReason,
                    stopHookActive: stopHookActive,
                    providerSleepActivity: providerSleepActivity
                )
            )
            switch response {
            case .teamHookOutput(let output):
                print(output)
            case .error, .serverBusy:
                if event == .postToolUse || event == .postToolUseFailure {
                    stageAttentionProgress()
                }
                print(Self.unrenderedHookOutput(runtime: runtime, event: event))
            default:
                print(Self.unrenderedHookOutput(runtime: runtime, event: event))
            }
        } catch {
            if event == .postToolUse || event == .postToolUseFailure {
                stageAttentionProgress()
            }
            print(Self.unrenderedHookOutput(runtime: runtime, event: event))
        }
    }

    /// AGENT-6.49: hook output when Graftty could not render the hook. The
    /// SessionStart skill guidance is the only Graftty context a session
    /// receives, so keep it when the app is unreachable, busy, or failing —
    /// but only inside a Graftty terminal. The plugins are user-global, and
    /// agents started elsewhere must not get Graftty's worktree rules.
    static func unrenderedHookOutput(
        runtime: TeamHookRuntime,
        event: TeamHookEvent,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        guard event == .sessionStart,
              environment["GRAFTTY_SOCK"]?.isEmpty == false,
              let output = try? TeamHookRenderer.sessionStart(runtime: runtime) else {
            return "{}"
        }
        return output
    }

    private func updateClaudeNativePresence(
        event: TeamHookEvent,
        sessionID: String,
        worktreePath: String,
        paneSessionName: String?
    ) {
        guard let resolved = TeamPresenceResolution.resolveTeamAndWorktree(
            worktreePath: worktreePath
        ) else {
            return
        }
        let teamID = TeamLookup.id(of: resolved.team)
        let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let canonicalAgentID = TeamAgentIdentity(
            runtime: .claude,
            nativeSessionID: sessionID
        ).rawValue

        let prior = try? storage.read(
            teamID: teamID,
            worktree: worktreePath,
            runtime: .claude,
            paneSessionName: paneSessionName,
            agentID: canonicalAgentID
        )
        // PostToolUse fires on every tool call; skip registry and presence
        // directory scans while this exact identity still has a live socket.
        // SessionStart replacement is serialized, and a superseded identity's
        // file is removed, so its later hooks cannot take this fast path.
        if event == .postToolUse,
           let prior,
           prior.runtimeSessionID == sessionID,
           case .claude(let socketPath, _)? = prior.transport,
           ClaudePeerSessionRegistry.isSocket(atPath: socketPath) {
            return
        }
        // Claude's Stop hook fires at the end of every assistant turn — the
        // exact moment native peer delivery exists to wake — so `.stop`
        // refreshes the record rather than deleting it. The record is
        // removed only when the native registry no longer lists a live
        // session (stale-presence cleanup handles process exit as well).
        let registry = ClaudePeerSessionRegistry()
        guard let record = Self.resolveClaudeNativePresence(
            event: event,
            lookup: {
                registry.presenceRecord(
                    sessionID: sessionID,
                    expectedWorktree: worktreePath,
                    teamID: teamID,
                    paneSessionName: paneSessionName,
                    agentID: canonicalAgentID,
                    registeredAt: prior?.registeredAt ?? Date()
                )
            },
            wait: { Thread.sleep(forTimeInterval: 0.02) }
        ) else {
            if event == .stop {
                try? storage.delete(
                    teamID: teamID,
                    worktree: worktreePath,
                    runtime: .claude,
                    paneSessionName: paneSessionName,
                    agentID: canonicalAgentID
                )
            }
            return
        }
        _ = try? ClaudeHookSessionBinder.bind(
            record,
            event: event,
            storage: storage
        )
    }

    /// Claude can invoke SessionStart just before its native peer registry
    /// file becomes visible. Retry that one lifecycle boundary briefly so a
    /// `/clear` identity can still replace the prior binding. Routine hooks
    /// remain single-lookups because they run on every tool call.
    static func resolveClaudeNativePresence(
        event: TeamHookEvent,
        lookup: () -> TeamPresenceRecord?,
        wait: () -> Void
    ) -> TeamPresenceRecord? {
        let maximumAttempts = event == .sessionStart ? 5 : 1
        for attempt in 1...maximumAttempts {
            if let record = lookup() {
                return record
            }
            if attempt < maximumAttempts {
                wait()
            }
        }
        return nil
    }

    private func bindCodexNativeSession(
        event: TeamHookEvent,
        sessionID: String,
        worktreePath: String,
        paneSessionName: String?
    ) {
        guard let paneSessionName,
              let agentID = ProcessInfo.processInfo.environment["GRAFTTY_AGENT_ID"],
              TeamAgentIdentity(rawValue: agentID)?.runtime == .codex,
              let resolved = TeamPresenceResolution.resolveTeamAndWorktree(
                  worktreePath: worktreePath
              ) else {
            return
        }
        let root = TeamPresenceStorage.defaultRoot()
        _ = try? CodexHookSessionBinder.bind(
            threadID: sessionID,
            teamID: TeamLookup.id(of: resolved.team),
            worktree: resolved.worktreePath,
            paneSessionName: paneSessionName,
            agentID: agentID,
            allowRebind: event == .sessionStart,
            presenceStorage: TeamPresenceStorage(rootDirectory: root),
            sessionStorage: CodexAppServerSessionStorage(rootDirectory: root)
        )
    }
}

enum TeamInboxReadMode: Equatable {
    case consumeUnread
    case peekUnread
    case history
}

struct TeamInbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Read unread team messages; marks displayed messages read",
        discussion: "Use --keep-unread to peek without changing delivery state, or --history to inspect prior messages. Diagnostic selectors also peek."
    )

    @Option(name: .long, help: "Worktree path or member name to inspect")
    var worktree: String?

    @Option(name: .long, help: "Repository path to inspect")
    var repo: String?

    @Option(name: .long, help: "Member name to inspect")
    var member: String?

    @Flag(
        name: [.customLong("keep-unread"), .customLong("unread")],
        help: "Peek at unread messages without marking them read (--unread is a compatibility alias)"
    )
    var keepUnread: Bool = false

    @Flag(name: .long, help: "Inspect message history without changing delivery state")
    var history: Bool = false

    @Flag(name: .long, help: "Show all matching messages by fetching every page")
    var all: Bool = false

    @Flag(name: .long, help: "Print JSON")
    var json: Bool = false

    var readMode: TeamInboxReadMode {
        if history { return .history }
        if keepUnread || hasDiagnosticSelector {
            return .peekUnread
        }
        return .consumeUnread
    }

    private var hasDiagnosticSelector: Bool {
        worktree != nil || repo != nil || member != nil
    }

    func validate() throws {
        if history, keepUnread {
            throw ValidationError("--history cannot be combined with --keep-unread or --unread")
        }
    }

    func run() throws {
        let callerWorktree: String? = if readMode == .consumeUnread {
            try CLIEnv.resolveWorktree()
        } else {
            try TeamDiagnosticScope.resolveCaller(worktree: worktree, repo: repo)
        }
        try execute(
            callerWorktree: callerWorktree,
            callerAgentID: callerWorktree.flatMap {
                TeamMessageInput.currentAgentID(worktreePath: $0)
            },
            sendRequest: CLIEnv.sendRequest,
            writeOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            writeError: CLIEnv.printError
        )
    }

    func execute(
        callerWorktree: String?,
        callerAgentID: String? = nil,
        sendRequest: (NotificationMessage) throws -> ResponseMessage,
        writeOutput: (Data) throws -> Void,
        writeError: (String) -> Void
    ) throws {
        var pages: [[TeamInboxMessage]] = []
        var beforeID: String?
        var afterID: String?
        var snapshotThroughID: String?
        var seenCursors: Set<String> = []

        while true {
            let response = try sendRequest(
                .teamInbox(TeamInboxPageRequest(
                    callerWorktree: callerWorktree,
                    callerAgentID: callerAgentID,
                    consuming: readMode == .consumeUnread,
                    worktree: worktree,
                    repo: repo,
                    member: member,
                    unread: readMode != .history,
                    all: all,
                    beforeID: beforeID,
                    afterID: afterID,
                    snapshotThroughID: snapshotThroughID,
                    forwardPagination: readMode == .history ? nil : true,
                    limit: all
                        ? TeamInboxDiagnosticPage.maximumLimit
                        : TeamInboxDiagnosticPage.defaultLimit
                ))
            )
            let (messages, nextBeforeID, nextAfterID, responseSnapshotThroughID) = try CLIEnv.expect(
                response, for: "team inbox", writeError: writeError
            ) {
                if case let .teamInbox(messages, before, after, snapshot) = $0 { (messages, before, after, snapshot) } else { nil }
            }
            if readMode == .consumeUnread,
               !messages.allSatisfy({ Self.isDeliverable($0, to: callerAgentID) }) {
                writeError("Team inbox response is not scoped to this agent; update or restart the Graftty app before consuming provider-targeted messages")
                throw ExitCode(1)
            }
            guard readMode == .history || messages.isEmpty || responseSnapshotThroughID != nil else {
                writeError("Team inbox response is missing fixed-snapshot support; update or restart the Graftty app before reading unread messages")
                throw ExitCode(1)
            }
            pages.append(messages)
            if snapshotThroughID == nil {
                snapshotThroughID = responseSnapshotThroughID
            }
            let nextCursor = readMode == .history ? nextBeforeID : nextAfterID
            guard all, let nextCursor else { break }
            guard seenCursors.insert(nextCursor).inserted else {
                writeError("Team inbox pagination returned a repeated cursor")
                throw ExitCode(1)
            }
            if readMode == .history {
                beforeID = nextCursor
            } else {
                afterID = nextCursor
            }
        }

        let messages = readMode == .history
            ? pages.reversed().flatMap { $0 }
            : pages.flatMap { $0 }
        let output: Data
        if json {
            var data = try JSONEncoder().encode(messages)
            data.append(0x0A)
            output = data
        } else {
            let text = messages.map(TeamOutput.inboxLine).joined(separator: "\n")
            output = Data((text.isEmpty ? "" : text + "\n").utf8)
        }
        try writeOutput(output)

        guard readMode == .consumeUnread, let throughID = messages.last?.id else {
            if readMode == .peekUnread || hasDiagnosticSelector {
                writeError(Self.peekGuidance)
            } else if messages.isEmpty, !json, readMode != .history {
                writeError("no unread team messages")
            }
            return
        }
        guard let callerWorktree else {
            writeError("Cannot advance team inbox outside a tracked worktree")
            throw ExitCode(1)
        }
        let response: ResponseMessage
        do {
            response = try sendRequest(
                .teamInboxAdvance(
                    callerWorktree: callerWorktree,
                    callerAgentID: callerAgentID,
                    throughID: throughID
                )
            )
        } catch {
            writeError(Self.advanceFailureGuidance)
            writeError("Failed to advance team inbox: \(error)")
            throw ExitCode(1)
        }
        try CLIEnv.expect(response, for: "team inbox", writeError: {
            writeError(Self.advanceFailureGuidance)
            writeError($0)
        }) { $0 == .ok ? () : nil }
    }

    private static let peekGuidance = "Inbox left unread. To mark that worktree's messages read, run `graftty team inbox` from that worktree without peek or diagnostic flags. Do not edit Graftty state files."
    private static let advanceFailureGuidance = "Messages were displayed but remain unread; rerun `graftty team inbox`. Do not edit Graftty state files."

    private static func isDeliverable(
        _ message: TeamInboxMessage,
        to callerAgentID: String?
    ) -> Bool {
        if message.to.runtime == nil, message.to.agentID == nil { return true }
        guard let identity = callerAgentID.flatMap(TeamAgentIdentity.init(rawValue:)) else {
            return false
        }
        guard message.to.runtime == nil || message.to.runtime == identity.runtime.rawValue else {
            return false
        }
        return message.to.agentID == nil || message.to.agentID == identity.rawValue
    }
}

struct TeamMsg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Hidden alias of `team send` without --stdin or --urgent.",
        shouldDisplay: false
    )

    @Argument(help: "Worktree name/path, <path>#<runtime>, or <path>#<agent-id>")
    var address: String

    @Argument(help: "Message text")
    var text: String

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(request(
            callerWorktree: worktreePath,
            callerAgentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath)
        ))
        try CLIEnv.expectOk(response, for: "team msg")
    }

    func request(callerWorktree: String, callerAgentID: String?) -> NotificationMessage {
        .teamSend(callerWorktree: callerWorktree, callerAgentID: callerAgentID, recipient: address, text: text,
                  priority: .normal)
    }
}

struct TeamList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the members of this worktree's team"
    )

    @Flag(name: .long, help: "Print stable JSON instead of human-formatted rows")
    var json: Bool = false

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.teamList(callerWorktree: worktreePath))
        try TeamOutput.printMembers(response, json: json, command: "team list")
    }
}

struct TeamRegister: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Announce agent presence for the current worktree."
    )

    @Option(name: .long, help: "Runtime: codex or claude")
    var runtime: String

    @Option(name: .long, help: "PID of the long-running agent process to register")
    var pid: Int32?

    @Option(name: .long, help: "Canonical Graftty agent ID")
    var agentID: String?

    @Option(name: .long, help: "Stable native provider session identifier")
    var sessionID: String?

    @Option(name: .long, help: "Provider display label (not a routing identity)")
    var nativeName: String?

    func run() throws {
        guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        let runtimeIdentity = try TeamRegisterPIDResolver.resolve(explicitPID: pid)
        guard let resolved = TeamPresenceResolution.resolveCurrentWorktree() else {
            // No team for this cwd — silently no-op so it's safe to call
            // unconditionally from a wrapper script.
            return
        }
        let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let teamID = TeamLookup.id(of: resolved.team)
        let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        )
        let resolvedAgentID = agentID
            ?? ProcessInfo.processInfo.environment["GRAFTTY_AGENT_ID"]
        if let resolvedAgentID {
            guard let identity = TeamAgentIdentity(rawValue: resolvedAgentID) else {
                throw ValidationError("--agent-id must be shaped as <runtime>-<12 lowercase hex characters>")
            }
            guard identity.runtime == runtimeValue else {
                throw ValidationError("--agent-id runtime must match --runtime")
            }
        }
        let record = TeamPresenceRecord(
            teamID: teamID,
            worktree: resolved.worktreePath,
            runtime: runtimeValue,
            paneSessionName: paneSessionName,
            pid: runtimeIdentity.pid,
            processStartTimeMicroseconds: runtimeIdentity.processStartTimeMicroseconds,
            registeredAt: Date(),
            runtimeSessionID: sessionID,
            nativeDisplayName: nativeName,
            agentID: resolvedAgentID
        )
        try storage.write(record)
        _ = try? TeamPresenceResolution.deleteLegacyMemberNamePresence(
            storage: storage,
            teamID: teamID,
            resolved: resolved,
            runtime: runtimeValue,
            paneSessionName: paneSessionName
        )
        try? TeamEventLog.defaultLog().append(
            .init(teamID: teamID, kind: .registered, detail: [
                "worktree": resolved.worktreePath,
                "member": resolved.memberName,
                "runtime": runtimeValue.rawValue,
                "pid": String(record.pid),
                "pane_session_name": paneSessionName ?? "",
            ])
        )
    }
}

enum TeamRegisterPIDResolver {
    struct Identity: Equatable {
        let pid: Int32
        let processStartTimeMicroseconds: Int64?
    }

    static func resolve(
        explicitPID: Int32?,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        startTimeMicroseconds: (Int32) -> Int64? = { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
    ) throws -> Identity {
        guard let explicitPID else {
            return Identity(
                pid: processIdentifier,
                processStartTimeMicroseconds: startTimeMicroseconds(processIdentifier)
            )
        }
        guard explicitPID > 0 else {
            throw ValidationError("--pid must be greater than 0")
        }
        guard let startTime = startTimeMicroseconds(explicitPID) else {
            throw ValidationError("--pid must identify a running process with a readable start time")
        }
        return Identity(pid: explicitPID, processStartTimeMicroseconds: startTime)
    }
}

struct TeamUnregister: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unregister",
        abstract: "Clear agent presence for the current worktree."
    )

    @Option(name: .long, help: "Runtime: codex or claude")
    var runtime: String

    @Option(name: .long, help: "Canonical Graftty agent ID")
    var agentID: String?

    func run() throws {
        guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        guard let resolved = TeamPresenceResolution.resolveCurrentWorktree() else {
            return
        }
        let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let teamID = TeamLookup.id(of: resolved.team)
        let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        )
        let resolvedAgentID = agentID
            ?? ProcessInfo.processInfo.environment["GRAFTTY_AGENT_ID"]
        let prior = try TeamUnregisterCore.unregister(
            storage: storage,
            teamID: teamID,
            worktree: resolved.worktreePath,
            runtime: runtimeValue,
            paneSessionName: paneSessionName,
            agentID: resolvedAgentID
        )
        let legacyPrior = try TeamPresenceResolution.deleteLegacyMemberNamePresence(
            storage: storage,
            teamID: teamID,
            resolved: resolved,
            runtime: runtimeValue,
            paneSessionName: paneSessionName
        )
        if prior != nil || legacyPrior != nil {
            try? TeamEventLog.defaultLog().append(
                .init(teamID: teamID, kind: .unregistered, detail: [
                    "worktree": resolved.worktreePath,
                    "member": resolved.memberName,
                    "runtime": runtimeValue.rawValue,
                    "pane_session_name": paneSessionName ?? "",
                ])
            )
        }
    }
}

struct TeamCodexAppServer: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "codex-app-server",
        subcommands: [
            TeamCodexAppServerRegister.self,
            TeamCodexAppServerUnregister.self,
            TeamCodexAppServerResolveBinary.self,
        ]
    )
}

struct TeamCodexAppServerResolveBinary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve-binary",
        abstract: "Print the native Codex executable when a Node launcher is installed."
    )

    @Option(name: .long) var realBinary: String

    func run() {
        print(CodexDeliveryBinaryResolver.resolve(realBinary))
    }
}

struct TeamCodexAppServerRegister: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Record a Codex app-server session for this pane."
    )

    @Option(name: .long) var socket: String
    @Option(name: .long) var realBinary: String
    @Option(name: .long) var appServerPid: Int32
    @Option(name: .long) var ownerPid: Int32

    func run() throws {
        guard let resolved = TeamPresenceResolution.resolveCurrentWorktree() else {
            return
        }
        guard let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        let identity = try TeamCodexAppServerPIDResolver.resolve(appServerPid: appServerPid)
        let ownerIdentity = try TeamCodexAppServerPIDResolver.resolve(appServerPid: ownerPid)
        _ = try TeamCodexAppServerCore.register(
            storage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
            teamID: TeamLookup.id(of: resolved.team),
            worktree: resolved.worktreePath,
            paneSessionName: paneSessionName,
            socketPath: socket,
            realBinaryPath: realBinary,
            appServerPID: identity.pid,
            appServerProcessStartTimeMicroseconds: identity.processStartTimeMicroseconds,
            ownerPID: ownerIdentity.pid,
            ownerProcessStartTimeMicroseconds: ownerIdentity.processStartTimeMicroseconds,
            registeredAt: Date()
        )
    }
}

struct TeamCodexAppServerUnregister: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unregister",
        abstract: "Forget this pane's Codex app-server session."
    )

    @Option(name: .long) var socket: String?
    @Option(name: .long) var appServerPid: Int32?

    func run() throws {
        guard let resolved = TeamPresenceResolution.resolveCurrentWorktree() else {
            return
        }
        guard let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        _ = try TeamCodexAppServerCore.unregister(
            storage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
            teamID: TeamLookup.id(of: resolved.team),
            worktree: resolved.worktreePath,
            paneSessionName: paneSessionName,
            expectedSocketPath: socket,
            expectedAppServerPID: appServerPid
        )
    }
}

enum TeamCodexAppServerPIDResolver {
    struct Identity: Equatable {
        let pid: Int32
        let processStartTimeMicroseconds: Int64
    }

    static func resolve(
        appServerPid: Int32,
        startTimeMicroseconds: (Int32) -> Int64? = { ProcessIdentityReader.startTimeMicroseconds(ofPID: $0) }
    ) throws -> Identity {
        guard appServerPid > 0 else {
            throw ValidationError("--app-server-pid must be greater than 0")
        }
        guard let startTime = startTimeMicroseconds(appServerPid) else {
            throw ValidationError("--app-server-pid must identify a running process with a readable start time")
        }
        return Identity(pid: appServerPid, processStartTimeMicroseconds: startTime)
    }
}

/// AGENT-6.47: compatibility stub for Claude sessions launched by an older
/// Graftty, whose inline `--settings` Stop hooks still spawn
/// `graftty team watch-inbox claude`. The provider plugins deliver inbox
/// messages natively now, so the watcher exits at once without output.
struct TeamWatchInbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch-inbox",
        abstract: "Removed; accepted so sessions from older Graftty versions exit cleanly.",
        shouldDisplay: false
    )

    @Argument(parsing: .allUnrecognized)
    var ignoredArguments: [String] = []

    func run() throws {
        Self.drainHookPayload(.standardInput)
    }

    /// Drains the hook payload so the runtime's stdin write never hits EPIPE.
    static func drainHookPayload(_ stdin: FileHandle) {
        _ = stdin.readDataToEndOfFile()
    }
}

struct InternalGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "internal",
        abstract: "Internal subcommands invoked by graftty itself; not meant for direct use.",
        subcommands: [SyncCodexHome.self, ClaudePeerSend.self, SleepGuard.self]
    )
}

/// Temporary live-session harness for AGENT-6.1. Keeping this under
/// `internal` lets us test Claude's native transport without committing the
/// team-routing surface to an undocumented peer protocol.
struct ClaudePeerSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude-peer-send",
        abstract: "Send a protocol-v1 message directly to a Claude peer socket."
    )

    @Option(name: .long, help: "Claude session's Unix-domain socket path")
    var socket: String

    @Option(name: .long, help: "Optional local socket Claude can reply to")
    var replySocket: String?

    @Option(name: .long, help: "Peer display name shown by Claude")
    var fromName: String = "Graftty prototype"

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Message text")
    var text: String?

    func validate() throws {
        if stdin, text != nil {
            throw ValidationError("message text and --stdin are mutually exclusive")
        }
        if !stdin, text == nil {
            throw ValidationError("provide message text or --stdin")
        }
    }

    func run() throws {
        let body: String
        if stdin {
            body = String(
                decoding: FileHandle.standardInput.readDataToEndOfFile(),
                as: UTF8.self
            )
        } else {
            body = text ?? ""
        }
        let messageID = try ClaudePeerSocketClient.sendUserMessage(
            body,
            to: socket,
            replySocketPath: replySocket,
            senderName: fromName
        )
        print(messageID.uuidString.lowercased())
    }
}

struct SyncCodexHome: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-codex-home",
        abstract: "Rebuild the CODEX_HOME mirror under <rootDirectory>/codex-home/."
    )

    func run() throws {
        let mirror = CodexHomeMirror(
            sourceDirectory: CodexHomeMirror.defaultSourceDirectory(),
            mirrorDirectory: CodexHomeMirror.defaultMirrorDirectory()
        )
        try mirror.rebuild()
    }
}

extension TeamPresenceResolution {
    /// Resolves the team of the worktree containing the current directory.
    static func resolveCurrentWorktree() -> Resolved? {
        guard let worktreePath = try? WorktreeResolver.resolve() else {
            return nil
        }
        return resolveTeamAndWorktree(worktreePath: worktreePath)
    }
}

private enum TeamMessageInput {
    static func currentAgentID(worktreePath: String) -> String? {
        AttentionReportIdentity.currentAgentID(worktreePath: worktreePath)
    }

    static func resolve(text: String?, stdin: Bool) throws -> String {
        if stdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let body = String(data: data, encoding: .utf8) ?? ""
            guard !body.isEmpty else {
                throw ValidationError("message text is required")
            }
            return body
        }
        guard let text, !text.isEmpty else {
            throw ValidationError("message text is required unless --stdin is set")
        }
        return text
    }
}

private enum TeamDiagnosticScope {
    static func resolveCaller(worktree: String?, repo: String?) throws -> String? {
        if worktree != nil || repo != nil {
            return try? WorktreeResolver.resolve()
        }
        return try CLIEnv.resolveWorktree()
    }
}

private enum TeamOutput {
    static func printMembers(_ response: ResponseMessage, json: Bool, command: String) throws {
        let (teamName, members) = try CLIEnv.expect(response, for: command) {
            if case let .teamList(teamName, members) = $0 { (teamName, members) } else { nil }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(TeamListDocument(team: teamName, members: members))
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print("team=\(teamName)  members=\(members.count)")
        for m in members {
            print(memberLine(m))
            for agent in m.agents {
                let label = agent.displayName.map { "  name=\($0)" } ?? ""
                print("  agent=\(agent.address)  runtime=\(agent.runtime.rawValue)  reachable=\(agent.isReachable)\(label)")
                if let pane = agent.paneSessionName {
                    print("    pane=\(pane)")
                }
            }
        }
    }

    static func memberLine(_ member: TeamListMember) -> String {
        "\(member.name)  branch=\(member.branch)  worktree=\(member.worktreePath)  main=\(member.isMainWorktree)  running=\(member.isRunning)"
    }

    static func inboxLine(_ message: TeamInboxMessage) -> String {
        "\(message.id)  from=\(message.from.member)  to=\(message.to.member)  priority=\(message.priority.rawValue)  \(message.body)"
    }
}
