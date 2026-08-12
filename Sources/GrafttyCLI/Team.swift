import ArgumentParser
import Darwin
import Foundation
import GrafttyKit

struct Team: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Coordinate with teammates in a Graftty agent team",
        subcommands: [
            TeamSend.self,
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
        abstract: "Send a message to a worktree or exact canonical agent address"
    )

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent: Bool = false

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Worktree name/path or <canonical-worktree-path>#<agent-id>")
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
        try CLIEnv.expectOk(response)
    }
}

struct TeamBroadcast: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Send the same message to every teammate"
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
        try CLIEnv.expectOk(response)
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
        try TeamOutput.printMembers(response, json: json)
    }
}

struct TeamHook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Render agent-team hook context for an agent runtime"
    )

    @Argument(help: "Runtime: codex or claude")
    var runtime: String

    @Argument(help: "Hook event: session-start, post-tool-use, or stop")
    var event: String

    @Option(name: [.customLong("session-id"), .customLong("session")], help: "Stable runtime session identifier")
    var sessionID: String?

    @Flag(name: .customLong("skill-managed"), help: "Suppress legacy team primer because the provider plugin supplies the Graftty skill")
    var skillManaged = false

    func validate() throws {
        guard TeamHookRuntime(rawValue: runtime) != nil else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        guard TeamHookEvent(rawValue: event) != nil else {
            throw ValidationError("event must be one of: session-start, post-tool-use, stop")
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
        if runtime == .claude, skillManaged, let resolvedSessionID {
            updateClaudeNativePresence(
                event: event,
                sessionID: resolvedSessionID,
                worktreePath: worktreePath,
                paneSessionName: paneSessionName
            )
        }
        if runtime == .codex, event != .stop, let resolvedSessionID {
            bindCodexNativeSession(
                event: event,
                sessionID: resolvedSessionID,
                worktreePath: worktreePath,
                paneSessionName: paneSessionName
            )
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
                    skillManaged: skillManaged
                )
            )
            switch response {
            case .teamHookOutput(let output):
                print(output)
            case .error:
                print("{}")
            case .serverBusy, .ok, .paneList, .paneShow, .teamList, .teamInbox,
                 .worktreeCreate, .worktreeRemove:
                print("{}")
            }
        } catch {
            print("{}")
        }
    }

    private func updateClaudeNativePresence(
        event: TeamHookEvent,
        sessionID: String,
        worktreePath: String,
        paneSessionName: String?
    ) {
        guard let resolved = TeamPresenceCLI.resolveTeamAndWorktree(
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
        // PostToolUse fires on every tool call; skip the registry scan and
        // rewrite while the stored record still points at a live socket.
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
        guard let record = ClaudePeerSessionRegistry().presenceRecord(
            sessionID: sessionID,
            expectedWorktree: worktreePath,
            teamID: teamID,
            paneSessionName: paneSessionName,
            agentID: canonicalAgentID,
            registeredAt: prior?.registeredAt ?? Date()
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
        try? storage.write(record)
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
              let resolved = TeamPresenceCLI.resolveTeamAndWorktree(
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
            sendRequest: CLIEnv.sendRequest,
            writeOutput: { try FileHandle.standardOutput.write(contentsOf: $0) },
            writeError: CLIEnv.printError
        )
    }

    func execute(
        callerWorktree: String?,
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
            switch response {
            case .teamInbox(let messages, let nextBeforeID, let nextAfterID, let responseSnapshotThroughID):
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
                continue
            case .error(let msg):
                writeError(msg)
                throw ExitCode(1)
            case .serverBusy:
                writeError(ResponseMessage.serverBusyMessage)
                throw ExitCode(1)
            case .ok, .paneList, .paneShow, .teamList, .teamHookOutput,
                 .worktreeCreate, .worktreeRemove:
                writeError("Unexpected response for team inbox")
                throw ExitCode(1)
            }
            break
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
                .teamInboxAdvance(callerWorktree: callerWorktree, throughID: throughID)
            )
        } catch {
            writeError(Self.advanceFailureGuidance)
            writeError("Failed to advance team inbox: \(error)")
            throw ExitCode(1)
        }
        switch response {
        case .ok:
            return
        case .error(let message):
            writeError(Self.advanceFailureGuidance)
            writeError(message)
            throw ExitCode(1)
        case .serverBusy:
            writeError(Self.advanceFailureGuidance)
            writeError(ResponseMessage.serverBusyMessage)
            throw ExitCode(1)
        case .paneList, .paneShow, .teamList, .teamHookOutput,
             .teamInbox, .worktreeCreate, .worktreeRemove:
            writeError(Self.advanceFailureGuidance)
            writeError("Unexpected response while advancing team inbox")
            throw ExitCode(1)
        }
    }

    private static let peekGuidance = "Inbox left unread. To mark that worktree's messages read, run `graftty team inbox` from that worktree without peek or diagnostic flags. Do not edit Graftty state files."
    private static let advanceFailureGuidance = "Messages were displayed but remain unread; rerun `graftty team inbox`. Do not edit Graftty state files."
}

struct TeamMsg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Send a message to a worktree or exact canonical agent address"
    )

    @Argument(help: "Worktree name/path or <canonical-worktree-path>#<agent-id>")
    var address: String

    @Argument(help: "Message text")
    var text: String

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(
            .teamSend(
                callerWorktree: worktreePath,
                callerAgentID: TeamMessageInput.currentAgentID(worktreePath: worktreePath),
                recipient: address,
                text: text,
                priority: .normal
            )
        )
        try CLIEnv.expectOk(response)
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
        try TeamOutput.printMembers(response, json: json)
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
        guard let resolved = TeamPresenceCLI.resolveTeamAndWorktree() else {
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
        _ = try? TeamPresenceCLI.deleteLegacyMemberNamePresence(
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
        guard let resolved = TeamPresenceCLI.resolveTeamAndWorktree() else {
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
        let legacyPrior = try TeamPresenceCLI.deleteLegacyMemberNamePresence(
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
        subcommands: [TeamCodexAppServerRegister.self, TeamCodexAppServerUnregister.self]
    )
}

struct TeamCodexAppServerRegister: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "register",
        abstract: "Record a Codex app-server session for this pane."
    )

    @Option(name: .long) var socket: String
    @Option(name: .long) var realBinary: String
    @Option(name: .long) var appServerPid: Int32

    func run() throws {
        guard let resolved = TeamPresenceCLI.resolveTeamAndWorktree() else {
            return
        }
        guard let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        let identity = try TeamCodexAppServerPIDResolver.resolve(appServerPid: appServerPid)
        _ = try TeamCodexAppServerCore.register(
            storage: CodexAppServerSessionStorage(rootDirectory: TeamPresenceStorage.defaultRoot()),
            teamID: TeamLookup.id(of: resolved.team),
            worktree: resolved.worktreePath,
            paneSessionName: paneSessionName,
            socketPath: socket,
            realBinaryPath: realBinary,
            appServerPID: identity.pid,
            appServerProcessStartTimeMicroseconds: identity.processStartTimeMicroseconds,
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
        guard let resolved = TeamPresenceCLI.resolveTeamAndWorktree() else {
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

enum CodexDeliveryBinaryResolver {
    static var targetTriple: String {
        #if os(macOS)
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #elseif arch(x86_64)
        return "x86_64-apple-darwin"
        #else
        return ""
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "aarch64-unknown-linux-musl"
        #elseif arch(x86_64)
        return "x86_64-unknown-linux-musl"
        #else
        return ""
        #endif
        #else
        return ""
        #endif
    }

    static var platformPackageName: String {
        #if os(macOS)
        #if arch(arm64)
        return "@openai/codex-darwin-arm64"
        #elseif arch(x86_64)
        return "@openai/codex-darwin-x64"
        #else
        return ""
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "@openai/codex-linux-arm64"
        #elseif arch(x86_64)
        return "@openai/codex-linux-x64"
        #else
        return ""
        #endif
        #else
        return ""
        #endif
    }

    static var platformPackageDirectoryName: String {
        platformPackageName.split(separator: "/").last.map(String.init) ?? ""
    }

    static func resolve(_ realBinaryPath: String, fileManager: FileManager = .default) -> String {
        guard !targetTriple.isEmpty, !platformPackageDirectoryName.isEmpty else {
            return realBinaryPath
        }

        let binaryURL = URL(fileURLWithPath: realBinaryPath)
        let scriptURL = binaryURL.resolvingSymlinksInPath()
        guard scriptURL.lastPathComponent == "codex.js",
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              script.hasPrefix("#!/usr/bin/env node")
        else {
            return realBinaryPath
        }

        let packageRoot = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let openAIOrgRoot = packageRoot.deletingLastPathComponent()
        let candidateURLs = [
            openAIOrgRoot
                .appendingPathComponent(platformPackageDirectoryName, isDirectory: true)
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent(targetTriple, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex"),
            packageRoot
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent(targetTriple, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex"),
        ]

        guard let nativeURL = candidateURLs.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return realBinaryPath
        }
        return nativeURL.path
    }
}

enum TeamCodexAppServerCore {
    @discardableResult
    static func register(
        storage: CodexAppServerSessionStorage,
        teamID: String,
        worktree: String,
        paneSessionName: String,
        socketPath: String,
        realBinaryPath: String,
        appServerPID: Int32,
        appServerProcessStartTimeMicroseconds: Int64,
        registeredAt: Date
    ) throws -> CodexAppServerSessionRecord {
        let deliveryBinaryPath = CodexDeliveryBinaryResolver.resolve(realBinaryPath)
        let record = CodexAppServerSessionRecord(
            teamID: teamID,
            worktree: worktree,
            paneSessionName: paneSessionName,
            socketPath: socketPath,
            realBinaryPath: deliveryBinaryPath,
            appServerPID: appServerPID,
            appServerProcessStartTimeMicroseconds: appServerProcessStartTimeMicroseconds,
            registeredAt: registeredAt
        )
        try storage.write(record)
        return record
    }

    @discardableResult
    static func unregister(
        storage: CodexAppServerSessionStorage,
        teamID: String,
        worktree: String,
        paneSessionName: String,
        expectedSocketPath: String? = nil,
        expectedAppServerPID: Int32? = nil
    ) throws -> CodexAppServerSessionRecord? {
        guard let prior = try storage.read(
            teamID: teamID,
            worktree: worktree,
            paneSessionName: paneSessionName
        ) else { return nil }
        if let expectedSocketPath, prior.socketPath != expectedSocketPath {
            return nil
        }
        if let expectedAppServerPID, prior.appServerPID != expectedAppServerPID {
            return nil
        }
        try storage.delete(
            teamID: teamID,
            worktree: worktree,
            paneSessionName: paneSessionName
        )
        return prior
    }
}

struct TeamWatchInbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch-inbox",
        abstract: "Long-running inbox watcher; exits 2 on a new directed message (used by Claude asyncRewake)."
    )

    @Argument(help: "Runtime: codex or claude")
    var runtime: String

    func run() throws {
        guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
            throw ValidationError("runtime must be one of: codex, claude")
        }

        // Hook payload is JSON on stdin: { "session_id": "...", "cwd": "..." }.
        // Read to EOF rather than `availableData` so the runtime's write
        // doesn't hit EPIPE if the payload is delivered in chunks; both
        // fields are best-effort, and we no-op silently if cwd isn't a
        // team worktree since wrapper hooks call us unconditionally.
        let stdinData = FileHandle.standardInput.readDataToEndOfFile()
        let payload = (try? JSONSerialization.jsonObject(with: stdinData) as? [String: Any]) ?? [:]

        // TEAM-9.1
        if AgentStopHookFilter.isSubagentStop(stdinJSON: payload) {
            return
        }

        guard let resolved = TeamPresenceCLI.resolveTeamAndWorktree() else {
            return
        }
        let teamID = TeamLookup.id(of: resolved.team)
        let presenceStorage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let records = try presenceStorage.listAll()
        let resolver = TeamDeliveryOwnershipResolver(
            records: { records },
            liveness: TeamWatchInboxDeliveryLiveness()
        )
        let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        )
        let decision = TeamWatchInboxOwnership.decision(
            runtime: runtimeValue,
            hookPayloadSessionID: payload["session_id"] as? String,
            fallbackSessionID: { UUID().uuidString },
            teamID: teamID,
            worktree: resolved.worktreePath,
            paneSessionName: paneSessionName,
            resolver: resolver
        )

        let inboxRoot = AppState.defaultDirectory
            .appendingPathComponent("team-inbox", isDirectory: true)
        let pidRoot = TeamPresenceStorage.defaultRoot()

        // The claim path skips rows pinned to other agents, so the watcher
        // must know this session's own canonical identity: the wrapper's
        // exported nonce, else the presence record it matches, else the
        // canonical hash of the native session ID (the same derivation the
        // hook and send paths use).
        let hookSessionID = payload["session_id"] as? String
        let inheritedIdentity = ProcessInfo.processInfo.environment["GRAFTTY_AGENT_ID"]
            .flatMap(TeamAgentIdentity.init(rawValue:))
        let watcherAgentID = (inheritedIdentity?.runtime == runtimeValue
            ? inheritedIdentity?.rawValue
            : nil)
            ?? TeamAgentSessionIdentityResolver.agentID(
                records: records,
                teamID: teamID,
                worktree: resolved.worktreePath,
                runtime: runtimeValue,
                sessionID: hookSessionID,
                paneSessionName: paneSessionName
            )
            ?? hookSessionID.map {
                TeamAgentIdentity(runtime: runtimeValue, nativeSessionID: $0).rawValue
            }

        let outcome = WatcherOutcome()
        guard let watcher = Self.makeWatcherIfOwner(decision: decision, makeWatcher: {
            InboxWatcher(
                sessionID: decision.sessionID,
                recipient: .init(
                    member: resolved.memberName,
                    worktree: resolved.worktreePath,
                    runtime: runtimeValue
                ),
                agentID: watcherAgentID,
                teamID: teamID,
                inboxRootDirectory: inboxRoot,
                outcome: outcome,
                pidFileRoot: pidRoot
            )
        }) else {
            return
        }

        Task.detached { await watcher.runUntilSignal() }

        // Block synchronously waiting for the watcher to resolve, then
        // bridge the outcome back to a real process exit. The internal
        // timeout matches Claude's asyncRewake ceiling and is normal,
        // silent teardown if this process wins that race.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var capturedExit: Int32 = 0
        nonisolated(unsafe) var capturedStderr = ""
        Task.detached {
            let result = await Self.waitForOutcome(outcome, timeout: 86_400)
            capturedExit = result.exitCode
            capturedStderr = result.stderr
            semaphore.signal()
        }
        semaphore.wait()

        Self.writeToStderr(capturedStderr)
        Foundation.exit(capturedExit)
    }

    static func waitForOutcome(
        _ outcome: WatcherOutcome,
        timeout: TimeInterval
    ) async -> WatcherOutcome.Result {
        do {
            return try await outcome.wait(timeout: timeout)
        } catch WatcherOutcome.WaitError.timeout {
            return WatcherOutcome.Result(exitCode: 0, stderr: "")
        } catch {
            return WatcherOutcome.Result(
                exitCode: 1,
                stderr: "watch-inbox wait failed: \(error)\n"
            )
        }
    }

    @discardableResult
    static func writeToStderr(
        _ text: String,
        fileDescriptor: Int32 = STDERR_FILENO
    ) -> Bool {
        guard !text.isEmpty else { return true }

        // A long-lived asyncRewake watcher may outlive the hook process that
        // owns its stderr pipe. Disable SIGPIPE for this descriptor, then use
        // the POSIX writer so EPIPE/EBADF becomes a discarded Swift error
        // instead of an uncatchable NSFileHandleOperationException.
        _ = Darwin.fcntl(fileDescriptor, F_SETNOSIGPIPE, 1)
        do {
            try SocketIO.writeAll(fd: fileDescriptor, string: text)
            return true
        } catch {
            return false
        }
    }

    static func makeWatcherIfOwner<Watcher>(
        decision: TeamWatchInboxOwnershipDecision,
        makeWatcher: () throws -> Watcher
    ) rethrows -> Watcher? {
        guard decision.shouldArmWatcher else { return nil }
        return try makeWatcher()
    }
}

private struct TeamWatchInboxDeliveryLiveness: TeamDeliveryLivenessChecking {
    func isLivePaneSession(_ sessionName: String) -> Bool {
        !sessionName.isEmpty
    }

    func processStartTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        ProcessIdentityReader.startTimeMicroseconds(ofPID: pid)
    }
}

struct InternalGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "internal",
        abstract: "Internal subcommands invoked by graftty itself; not meant for direct use.",
        subcommands: [SyncCodexHome.self, ClaudePeerSend.self]
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
        let cliPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let mirror = CodexHomeMirror(
            sourceDirectory: CodexHomeMirror.defaultSourceDirectory(),
            mirrorDirectory: CodexHomeMirror.defaultMirrorDirectory(),
            grafttyCLIPath: cliPath,
            grafttyHooksEnabled: ProcessInfo.processInfo.environment["GRAFTTY_PROVIDER_PLUGINS"] != "1"
        )
        try mirror.rebuild()
    }
}

/// Helpers shared by `team register` / `team unregister` / `team watch-inbox`.
/// Presence ownership and inbox delivery use the canonical worktree path;
/// the member name is display-only compatibility metadata.
/// Returns nil when the cwd is not in a tracked, team-enabled worktree
/// so the wrapper-driven CLI calls can no-op cleanly.
enum TeamPresenceCLI {
    struct Resolved {
        let team: TeamView
        let worktreePath: String
        let memberName: String
    }

    static func resolveTeamAndWorktree() -> Resolved? {
        guard let state = try? AppState.load(from: AppState.defaultDirectory) else {
            return nil
        }
        guard let worktreePath = try? WorktreeResolver.resolve() else {
            return nil
        }
        return resolveTeamAndWorktree(state: state, worktreePath: worktreePath)
    }

    static func resolveTeamAndWorktree(worktreePath: String) -> Resolved? {
        guard let state = try? AppState.load(from: AppState.defaultDirectory) else {
            return nil
        }
        return resolveTeamAndWorktree(state: state, worktreePath: worktreePath)
    }

    static func resolveTeamAndWorktree(state: AppState, worktreePath: String) -> Resolved? {
        guard let team = TeamLookup.team(for: worktreePath, in: state.repos) else {
            return nil
        }
        guard let worktreeName = team.members.first(where: { $0.worktreePath == worktreePath })?.name else {
            return nil
        }
        return Resolved(team: team, worktreePath: worktreePath, memberName: worktreeName)
    }

    @discardableResult
    static func deleteLegacyMemberNamePresence(
        storage: TeamPresenceStorage,
        teamID: String,
        resolved: Resolved,
        runtime: TeamHookRuntime,
        paneSessionName: String?
    ) throws -> TeamPresenceRecord? {
        guard resolved.memberName != resolved.worktreePath else { return nil }
        let prior = try storage.read(
            teamID: teamID,
            worktree: resolved.memberName,
            runtime: runtime,
            paneSessionName: paneSessionName
        )
        try storage.delete(
            teamID: teamID,
            worktree: resolved.memberName,
            runtime: runtime,
            paneSessionName: paneSessionName
        )
        return prior
    }
}

private enum TeamMessageInput {
    static func currentAgentID(worktreePath: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["GRAFTTY_AGENT_ID"]
            .flatMap(TeamAgentIdentity.init(rawValue:)) {
            return explicit.rawValue
        }
        let records = (try? TeamPresenceStorage(
            rootDirectory: TeamPresenceStorage.defaultRoot()
        ).listAll()) ?? []
        return TeamCallerAgentIdentityResolver.resolve(
            explicitAgentID: nil,
            worktree: worktreePath,
            paneSessionName: TeamRegisterPaneResolver.paneSessionName(env: environment),
            records: records,
            isReachable: TeamAgentReachability.isReachable
        )
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
    static func printMembers(_ response: ResponseMessage, json: Bool) throws {
        switch response {
        case .teamList(let teamName, let members):
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(
                    TeamListDocument(team: teamName, members: members)
                )
                print(String(decoding: data, as: UTF8.self))
            } else {
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
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .serverBusy:
            CLIEnv.printError(ResponseMessage.serverBusyMessage)
            throw ExitCode(1)
        case .ok, .paneList, .paneShow, .teamHookOutput, .teamInbox,
             .worktreeCreate, .worktreeRemove:
            CLIEnv.printError("Unexpected response for team members")
            throw ExitCode(1)
        }
    }

    static func memberLine(_ member: TeamListMember) -> String {
        "\(member.name)  branch=\(member.branch)  worktree=\(member.worktreePath)  main=\(member.isMainWorktree)  running=\(member.isRunning)"
    }

    static func inboxLine(_ message: TeamInboxMessage) -> String {
        "\(message.id)  from=\(message.from.member)  to=\(message.to.member)  priority=\(message.priority.rawValue)  \(message.body)"
    }
}
