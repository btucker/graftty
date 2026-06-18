import ArgumentParser
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
            TeamWatchInbox.self,
        ]
    )
}

struct TeamSend: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "send",
        abstract: "Send a message to a teammate by name"
    )

    @Flag(name: .long, help: "Deliver at the next post-tool hook boundary when possible")
    var urgent: Bool = false

    @Flag(name: .long, help: "Read message text from standard input")
    var stdin: Bool = false

    @Argument(help: "Member name of the teammate to message")
    var member: String

    @Argument(help: "Message text")
    var text: String?

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let body = try TeamMessageInput.resolve(text: text, stdin: stdin)
        let response = try CLIEnv.sendRequest(
            .teamSend(
                callerWorktree: worktreePath,
                recipient: member,
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

    func run() throws {
        let callerWorktree = try TeamDiagnosticScope.resolveCaller(worktree: worktree, repo: repo)
        let response = try CLIEnv.sendRequest(
            .teamMembers(callerWorktree: callerWorktree, worktree: worktree, repo: repo)
        )
        try TeamOutput.printMembers(response)
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
        do {
            let response = try SocketClient.sendExpectingResponse(
                .teamHook(
                    callerWorktree: worktreePath,
                    runtime: runtime,
                    event: event,
                    sessionID: resolvedSessionID,
                    paneSessionName: paneSessionName
                )
            )
            switch response {
            case .teamHookOutput(let output):
                print(output)
            case .error:
                print("{}")
            case .ok, .paneList, .paneShow, .teamList, .teamInbox:
                print("{}")
            }
        } catch {
            print("{}")
        }
    }
}

struct TeamInbox: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inbox",
        abstract: "Read team inbox messages without advancing agent cursors"
    )

    @Option(name: .long, help: "Worktree path or member name to inspect")
    var worktree: String?

    @Option(name: .long, help: "Repository path to inspect")
    var repo: String?

    @Option(name: .long, help: "Member name to inspect")
    var member: String?

    @Flag(name: .long, help: "Show unread messages only")
    var unread: Bool = false

    @Flag(name: .long, help: "Show all messages")
    var all: Bool = false

    @Flag(name: .long, help: "Print JSON")
    var json: Bool = false

    func run() throws {
        let callerWorktree = try TeamDiagnosticScope.resolveCaller(worktree: worktree, repo: repo)
        let response = try CLIEnv.sendRequest(
            .teamInbox(
                callerWorktree: callerWorktree,
                worktree: worktree,
                repo: repo,
                member: member,
                unread: unread,
                all: all
            )
        )
        switch response {
        case .teamInbox(let messages):
            if json {
                let data = try JSONEncoder().encode(messages)
                print(String(data: data, encoding: .utf8) ?? "[]")
            } else {
                for message in messages {
                    print(TeamOutput.inboxLine(message))
                }
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok, .paneList, .paneShow, .teamList, .teamHookOutput:
            CLIEnv.printError("Unexpected response for team inbox")
            throw ExitCode(1)
        }
    }
}

struct TeamMsg: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "msg",
        abstract: "Send a message to a teammate by name"
    )

    @Argument(help: "Member name (sanitized branch name) of the teammate to message")
    var member: String

    @Argument(help: "Message text")
    var text: String

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(
            .teamSend(callerWorktree: worktreePath, recipient: member, text: text, priority: .normal)
        )
        try CLIEnv.expectOk(response)
    }
}

struct TeamList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the members of this worktree's team"
    )

    func run() throws {
        let worktreePath = try CLIEnv.resolveWorktree()
        let response = try CLIEnv.sendRequest(.teamList(callerWorktree: worktreePath))
        try TeamOutput.printMembers(response)
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

    func run() throws {
        guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        let runtimeIdentity = try TeamRegisterPIDResolver.resolve(explicitPID: pid)
        guard let (team, worktreeName) = TeamPresenceCLI.resolveTeamAndWorktree() else {
            // No team for this cwd — silently no-op so it's safe to call
            // unconditionally from a wrapper script.
            return
        }
        let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let teamID = TeamLookup.id(of: team)
        let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        )
        let record = TeamPresenceRecord(
            teamID: teamID,
            worktree: worktreeName,
            runtime: runtimeValue,
            paneSessionName: paneSessionName,
            pid: runtimeIdentity.pid,
            processStartTimeMicroseconds: runtimeIdentity.processStartTimeMicroseconds,
            registeredAt: Date()
        )
        try storage.write(record)
        try? TeamEventLog.defaultLog().append(
            .init(teamID: teamID, kind: .registered, detail: [
                "worktree": worktreeName,
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

    func run() throws {
        guard let runtimeValue = TeamHookRuntime(rawValue: runtime) else {
            throw ValidationError("runtime must be one of: codex, claude")
        }
        guard let (team, worktreeName) = TeamPresenceCLI.resolveTeamAndWorktree() else {
            return
        }
        let storage = TeamPresenceStorage(rootDirectory: TeamPresenceStorage.defaultRoot())
        let teamID = TeamLookup.id(of: team)
        let paneSessionName = TeamRegisterPaneResolver.paneSessionName(
            env: ProcessInfo.processInfo.environment
        )
        let prior = try TeamUnregisterCore.unregister(
            storage: storage,
            teamID: teamID,
            worktree: worktreeName,
            runtime: runtimeValue,
            paneSessionName: paneSessionName
        )
        if prior != nil {
            try? TeamEventLog.defaultLog().append(
                .init(teamID: teamID, kind: .unregistered, detail: [
                    "worktree": worktreeName,
                    "runtime": runtimeValue.rawValue,
                    "pane_session_name": paneSessionName ?? "",
                ])
            )
        }
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

        let sessionID = (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? UUID().uuidString

        guard let (team, worktreeName) = TeamPresenceCLI.resolveTeamAndWorktree() else {
            return
        }
        let teamID = TeamLookup.id(of: team)

        let inboxRoot = AppState.defaultDirectory
            .appendingPathComponent("team-inbox", isDirectory: true)
        let pidRoot = TeamPresenceStorage.defaultRoot()

        let outcome = WatcherOutcome()
        let watcher = InboxWatcher(
            sessionID: sessionID,
            recipient: .init(member: worktreeName, runtime: runtimeValue),
            teamID: teamID,
            inboxRootDirectory: inboxRoot,
            outcome: outcome,
            pidFileRoot: pidRoot
        )

        Task.detached { await watcher.runUntilSignal() }

        // Block synchronously waiting for the watcher to resolve, then
        // bridge the outcome back to a real process exit. asyncRewake
        // declares timeout=86400, so we'll be killed by Claude's harness
        // long before this hits its own ceiling.
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var capturedExit: Int32 = 0
        nonisolated(unsafe) var capturedStderr = ""
        Task.detached {
            do {
                let result = try await outcome.wait(timeout: 86_400)
                capturedExit = result.exitCode
                capturedStderr = result.stderr
            } catch {
                capturedExit = 1
                capturedStderr = "watch-inbox timeout\n"
            }
            semaphore.signal()
        }
        semaphore.wait()

        if !capturedStderr.isEmpty {
            FileHandle.standardError.write(Data(capturedStderr.utf8))
        }
        Foundation.exit(capturedExit)
    }
}

struct InternalGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "internal",
        abstract: "Internal subcommands invoked by graftty itself; not meant for direct use.",
        subcommands: [SyncCodexHome.self]
    )
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
            grafttyCLIPath: cliPath
        )
        try mirror.rebuild()
    }
}

/// Helpers shared by `team register` / `team unregister` — both walk
/// the same path: cwd → AppState → TeamView → (team, worktree name).
/// Returns nil when the cwd is not in a tracked, team-enabled worktree
/// so the wrapper-driven CLI calls can no-op cleanly.
private enum TeamPresenceCLI {
    static func resolveTeamAndWorktree() -> (TeamView, String)? {
        guard let state = try? AppState.load(from: AppState.defaultDirectory) else {
            return nil
        }
        guard let worktreePath = try? WorktreeResolver.resolve() else {
            return nil
        }
        guard let team = TeamLookup.team(for: worktreePath, in: state.repos) else {
            return nil
        }
        guard let worktreeName = team.members.first(where: { $0.worktreePath == worktreePath })?.name else {
            return nil
        }
        return (team, worktreeName)
    }
}

private enum TeamMessageInput {
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
    static func printMembers(_ response: ResponseMessage) throws {
        switch response {
        case .teamList(let teamName, let members):
            print("team=\(teamName)  members=\(members.count)")
            for m in members {
                print(memberLine(m))
            }
        case .error(let msg):
            CLIEnv.printError(msg)
            throw ExitCode(1)
        case .ok, .paneList, .paneShow, .teamHookOutput, .teamInbox:
            CLIEnv.printError("Unexpected response for team members")
            throw ExitCode(1)
        }
    }

    static func memberLine(_ member: TeamListMember) -> String {
        "\(member.name)  branch=\(member.branch)  worktree=\(member.worktreePath)  role=\(member.role)  running=\(member.isRunning)"
    }

    static func inboxLine(_ message: TeamInboxMessage) -> String {
        "\(message.id)  from=\(message.from.member)  to=\(message.to.member)  priority=\(message.priority.rawValue)  \(message.body)"
    }
}
