import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Worktree: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create and remove worktrees",
        subcommands: [WorktreeAdd.self, WorktreeRemove.self]
    )
}

struct WorktreeAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add",
        abstract: "Create a worktree, open its first pane, and optionally launch an agent",
        discussion: """
        Examples:
          graftty worktree add fix-auth
          graftty worktree add fix-auth --agent codex
          graftty worktree add fix-auth --agent claude --prompt "Fix the auth tests"
          graftty worktree add fix-auth --agent codex --prompt-stdin <<'GRAFTTY_PROMPT'
          Review the failing tests without expanding $(shell syntax).
          GRAFTTY_PROMPT
          graftty worktree add review-pr --base origin/main --agent codex
          graftty worktree add review-pr --branch existing-branch --existing --agent codex

        On success, the command prints the worktree's stable message address.
        Send guidance with `graftty team send --stdin <address>`; messages
        queued before the agent process finishes starting are delivered at
        session start.
        """
    )

    @Argument(help: "Worktree directory name under <repo>/.worktrees")
    var name: String

    @Option(name: .long, help: "Branch name (default: normalized worktree name)")
    var branch: String?

    @Option(name: .long, help: "Git revision from which to create the new branch (default: repository default branch or HEAD)")
    var base: String?

    @Flag(name: .long, help: "Check out an existing local branch instead of creating a new branch")
    var existing: Bool = false

    @Option(name: .long, help: "Agent runtime to launch: codex or claude")
    var agent: String?

    @Option(name: .long, help: "Initial prompt passed to --agent")
    var prompt: String?

    @Flag(name: .long, help: "Read the initial agent prompt from standard input")
    var promptStdin: Bool = false

    @Option(name: .long, help: "Exact shell command to launch instead of --agent")
    var command: String?

    @Option(name: .long, help: "Maximum seconds to wait for Git hooks and pane creation")
    var timeout: Int = 300

    func validate() throws {
        if agent != nil && command != nil {
            throw ValidationError("--agent and --command are mutually exclusive")
        }
        if prompt != nil && promptStdin {
            throw ValidationError("--prompt and --prompt-stdin are mutually exclusive")
        }
        if (prompt != nil || promptStdin) && agent == nil {
            throw ValidationError("--prompt and --prompt-stdin require --agent")
        }
        if base != nil && existing {
            throw ValidationError("--base cannot be used with --existing")
        }
        if let agent, TeamHookRuntime(rawValue: agent) == nil {
            throw ValidationError("--agent must be one of: codex, claude")
        }
        if let command, command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ValidationError("--command must not be empty")
        }
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than 0")
        }
    }

    func run() throws {
        let names = WorktreeRequestNames.resolve(name: name, branch: branch, existing: existing)
        if let error = WorktreeCreationInput.validationError(
            worktreeName: names.worktree,
            branchName: names.branch,
            existing: existing,
            base: base
        ) {
            throw ValidationError(error)
        }

        let resolvedPrompt = try promptStdin ? Self.readPromptFromStdin() : prompt
        if let error = WorktreeAgentLaunchCommand.validationError(prompt: resolvedPrompt) {
            throw ValidationError(error)
        }
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        // Capability probes use the same two-second request transport as the
        // mutation. Give transient app stalls a short bounded retry window,
        // while preserving most of the caller's timeout for the real work.
        let capabilityDeadline = min(
            deadline,
            Date().addingTimeInterval(5)
        )
        try WorktreeCapability.require(
            .worktreeCreateIdempotencyCapability,
            unsupportedMessage: "the running Graftty app does not support safe worktree-create retries; quit and relaunch the updated app, then retry",
            verificationMessage: "could not verify safe worktree-create retries; quit and relaunch Graftty, then retry",
            retryTransportFailuresUntil: capabilityDeadline
        )
        let agentRuntime = agent.flatMap { TeamHookRuntime(rawValue: $0) }
        if agentRuntime != nil {
            try WorktreeCapability.require(
                .agentPromptStagingCapability,
                unsupportedMessage: "the running Graftty app does not support safe agent prompt staging; quit and relaunch the updated app, then retry",
                verificationMessage: "could not verify agent prompt staging support; quit and relaunch Graftty, then retry",
                retryTransportFailuresUntil: capabilityDeadline
            )
        }
        if base != nil {
            try WorktreeCapability.require(
                .worktreeBaseCapability,
                unsupportedMessage: "the running Graftty app does not support worktree --base; quit and relaunch the updated app, then retry",
                verificationMessage: "could not verify worktree --base support; quit and relaunch Graftty, then retry",
                retryTransportFailuresUntil: capabilityDeadline
            )
        }
        let callerWorktree = try CLIEnv.resolveWorktree()
        let operationID = UUID().uuidString.lowercased()
        var response = try Self.sendRequestRetryingTimeout(
            creationRequest(
                callerWorktree: callerWorktree,
                names: names,
                agentRuntime: agentRuntime,
                resolvedPrompt: resolvedPrompt,
                operationID: operationID
            ),
            operationID: operationID,
            deadline: deadline
        )

        while true {
            switch response {
            case .worktreeCreate(let operation):
                switch operation.state {
                case .pending:
                    guard Date() < deadline else {
                        CLIEnv.printError(
                            "timed out waiting for worktree creation; operation \(operation.operationID) may still finish"
                        )
                        throw ExitCode(1)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                    response = try Self.sendRequestRetryingTimeout(
                        .worktreeCreateStatus(operationID: operation.operationID),
                        operationID: operation.operationID,
                        deadline: deadline
                    )
                case .ready:
                    let path = WorktreeAgentLaunchCommand.shellLiteral(operation.worktreePath)
                    let address = WorktreeAgentLaunchCommand.shellLiteral(operation.messageAddress)
                    print("created worktree=\(path)  address=\(address)")
                    if let agent {
                        print("agent=\(agent)  message-with=graftty team send --stdin \(address)")
                    }
                    return
                case .failed:
                    CLIEnv.printError(operation.error ?? "worktree creation failed")
                    throw ExitCode(1)
                }
            case .error(let message):
                CLIEnv.printError(message)
                throw ExitCode(1)
            case .serverBusy:
                CLIEnv.printError(ResponseMessage.serverBusyMessage)
                throw ExitCode(1)
            case .ok, .paneList, .paneShow, .teamList, .teamHookOutput,
                 .teamInbox, .worktreeRemove:
                CLIEnv.printError("Unexpected response for worktree add")
                throw ExitCode(1)
            }
        }
    }

    static func readPromptFromStdin(
        fileHandle: FileHandle = .standardInput
    ) throws -> String {
        let maximumBytes = WorktreeAgentLaunchCommand.maximumPromptBytes
        var data = Data()
        while data.count <= maximumBytes {
            let remaining = maximumBytes + 1 - data.count
            guard let chunk = try fileHandle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        if data.count > maximumBytes {
            throw ValidationError(WorktreeAgentLaunchCommand.oversizedPromptError)
        }
        guard let prompt = String(data: data, encoding: .utf8), !prompt.isEmpty else {
            throw ValidationError("--prompt-stdin requires a non-empty UTF-8 prompt")
        }
        return prompt
    }

    func creationRequest(
        callerWorktree: String,
        names: (worktree: String, branch: String),
        agentRuntime: TeamHookRuntime?,
        resolvedPrompt: String?,
        operationID: String? = nil
    ) -> NotificationMessage {
        .createWorktree(
            callerWorktree: callerWorktree,
            worktreeName: names.worktree,
            branchName: names.branch,
            existing: existing,
            base: base,
            // The capability check in `run()` guarantees the app will replace
            // this bare fallback with its staged loader before starting Git.
            command: command ?? agentRuntime?.rawValue,
            agentRuntime: agentRuntime,
            agentPrompt: resolvedPrompt,
            operationID: operationID
        )
    }

    static func sendRequestRetryingTimeout(
        _ message: NotificationMessage,
        operationID: String,
        deadline: Date,
        send: (NotificationMessage) throws -> ResponseMessage = {
            try SocketClient.sendExpectingResponse($0)
        },
        sleep: (TimeInterval) -> Void = {
            Thread.sleep(forTimeInterval: $0)
        },
        writeError: (String) -> Void = CLIEnv.printError
    ) throws -> ResponseMessage {
        var operationMayExist: Bool
        if case .worktreeCreateStatus = message {
            operationMayExist = true
        } else {
            operationMayExist = false
        }
        while true {
            do {
                return try send(message)
            } catch let error as CLIError {
                switch error {
                case .socketBusy:
                    // Busy is a pre-dispatch rejection. With no earlier
                    // ambiguous failure, the server cannot have created the
                    // operation, so do not wait the full worktree deadline or
                    // claim that it may finish. Once a request might have been
                    // admitted, keep polling the stable operation ID.
                    guard operationMayExist else {
                        writeError(error.description)
                        throw ExitCode(1)
                    }
                    if Date() < deadline {
                        sleep(0.1)
                        continue
                    }
                    writeError(
                        "timed out waiting for worktree creation; operation \(operationID) may still finish"
                    )
                    throw ExitCode(1)
                case .socketTimeout, .socketClosedWithoutResponse,
                     .socketError:
                    operationMayExist = true
                    if Date() < deadline {
                        sleep(0.1)
                        continue
                    }
                    writeError(
                        "timed out waiting for worktree creation; operation \(operationID) may still finish"
                    )
                    throw ExitCode(1)
                case .notInsideWorktree, .appNotRunning, .staleControlSocket,
                     .socketPathTooLong, .responseTooLarge:
                    writeError(error.description)
                    throw ExitCode(1)
                }
            } catch {
                writeError("Decode error: \(error)")
                throw ExitCode(1)
            }
        }
    }

}

struct WorktreeRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Remove a linked worktree while preserving its branch",
        discussion: """
        The target may be an absolute worktree path, "." for the current
        worktree, or a worktree name printed by `graftty team list`.
        If that name exists in more than one repository, use an absolute path.

        Removal fails when Git finds modified, staged, or untracked files.
        Pass --force to mirror Graftty's “Force Delete” action.

        Examples:
          graftty worktree remove feature-auth
          graftty worktree remove /repo/.worktrees/feature-auth
          graftty worktree remove feature-auth --force
        """
    )

    @Argument(help: "Worktree name, absolute path, or . for the current worktree")
    var target: String

    @Flag(name: .long, help: "Remove even when the worktree contains uncommitted or untracked files")
    var force: Bool = false

    @Option(name: .long, help: "Maximum seconds to wait for worktree removal")
    var timeout: Int = 300

    func validate() throws {
        guard timeout > 0 else {
            throw ValidationError("--timeout must be greater than 0")
        }
    }

    func run() throws {
        let worktreePath: String
        if target == "." {
            worktreePath = try CLIEnv.resolveWorktree()
        } else {
            switch Self.resolveTarget(target) {
            case .resolved(let path):
                worktreePath = path
            case .unknown:
                throw ValidationError(
                    "unknown worktree '\(target)'; use an absolute tracked path or a name from `graftty team list`"
                )
            case .ambiguous(let paths):
                let candidates = paths.map { "  \($0)" }.joined(separator: "\n")
                throw ValidationError(
                    "worktree name '\(target)' is ambiguous; use an absolute path:\n\(candidates)"
                )
            }
        }

        try WorktreeCapability.require(
            .worktreeRemoveCapability,
            unsupportedMessage: "the running Graftty app does not support worktree remove; quit and relaunch the updated app, then retry",
            verificationMessage: "could not verify worktree remove support; quit and relaunch Graftty, then retry"
        )

        var response = try CLIEnv.sendRequest(removalRequest(worktreePath: worktreePath))
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while true {
            switch response {
            case .worktreeRemove(let operation):
                switch operation.state {
                case .pending:
                    guard Date() < deadline else {
                        CLIEnv.printError(
                            "timed out waiting for worktree removal; operation \(operation.operationID) may still finish"
                        )
                        throw ExitCode(1)
                    }
                    Thread.sleep(forTimeInterval: 0.1)
                    response = try CLIEnv.sendRequest(
                        .worktreeRemoveStatus(operationID: operation.operationID)
                    )
                case .removed:
                    let path = WorktreeAgentLaunchCommand.shellLiteral(
                        operation.worktreePath
                    )
                    print("removed worktree=\(path)  branch-preserved=true")
                    return
                case .failed:
                    CLIEnv.printError(Self.failureMessage(operation))
                    throw ExitCode(1)
                }
            case .error(let message):
                CLIEnv.printError(message)
                throw ExitCode(1)
            case .serverBusy:
                CLIEnv.printError(ResponseMessage.serverBusyMessage)
                throw ExitCode(1)
            case .ok, .paneList, .paneShow, .teamList, .teamHookOutput,
                 .teamInbox, .worktreeCreate:
                CLIEnv.printError("Unexpected response for worktree remove")
                throw ExitCode(1)
            }
        }
    }

    func removalRequest(worktreePath: String) -> NotificationMessage {
        .removeWorktree(worktreePath: worktreePath, force: force)
    }

    static func resolveTarget(
        _ target: String,
        stateDirectory: URL = AppState.defaultDirectory
    ) -> WorktreeRemoveTargetResolution {
        guard let state = try? AppState.load(from: stateDirectory) else {
            return .unknown
        }
        if NSString(string: target).isAbsolutePath {
            let standardized = URL(fileURLWithPath: target)
                .standardizedFileURL.path
            return state.worktree(forPath: standardized) == nil
                ? .unknown
                : .resolved(standardized)
        }
        let matches = state.repos
            .flatMap(\.worktrees)
            .filter {
                WorktreeNameSanitizer.sanitize($0.branch) == target
            }
            .map(\.path)
        switch matches.count {
        case 0:
            return .unknown
        case 1:
            return .resolved(matches[0])
        default:
            return .ambiguous(matches)
        }
    }

    static func failureMessage(_ operation: WorktreeRemoveStatus) -> String {
        var sections = [operation.error ?? "worktree removal failed"]
        if let shortStatus = operation.shortStatus, !shortStatus.isEmpty {
            sections.append(shortStatus)
        }
        if operation.forceAllowed {
            sections.append("Rerun with --force to remove it anyway.")
        }
        return sections.joined(separator: "\n\n")
    }
}

enum WorktreeRemoveTargetResolution: Equatable {
    case resolved(String)
    case unknown
    case ambiguous([String])
}

enum WorktreeCapability {
    static func require(
        _ request: NotificationMessage,
        unsupportedMessage: String,
        verificationMessage: String,
        retryTransportFailuresUntil deadline: Date? = nil,
        send: (NotificationMessage) throws -> ResponseMessage = {
            try SocketClient.sendExpectingResponse($0)
        },
        now: () -> Date = Date.init,
        sleep: (TimeInterval) -> Void = Thread.sleep(forTimeInterval:)
    ) throws {
        while true {
            let response: ResponseMessage
            do {
                response = try send(request)
            } catch let error as CLIError {
                switch error {
                case .socketTimeout, .socketClosedWithoutResponse,
                     .socketError:
                    if let deadline, now() < deadline {
                        sleep(0.1)
                        continue
                    }
                    CLIEnv.printError(verificationMessage)
                case .socketBusy:
                    if let deadline, now() < deadline {
                        sleep(0.1)
                        continue
                    }
                    CLIEnv.printError(error.description)
                case .notInsideWorktree, .appNotRunning, .staleControlSocket,
                     .socketPathTooLong, .responseTooLarge:
                    CLIEnv.printError(error.description)
                }
                throw ExitCode(1)
            } catch {
                CLIEnv.printError(verificationMessage)
                throw ExitCode(1)
            }

            switch response {
            case .ok:
                return
            case .error:
                CLIEnv.printError(unsupportedMessage)
            default:
                CLIEnv.printError(verificationMessage)
            }
            throw ExitCode(1)
        }
    }
}

enum WorktreeRequestNames {
    static func resolve(name: String, branch: String?, existing: Bool) -> (worktree: String, branch: String) {
        let worktree = normalize(name)
        let requestedBranch = branch ?? (existing ? name : worktree)
        return (worktree, existing ? requestedBranch : normalize(requestedBranch))
    }

    private static func normalize(_ value: String) -> String {
        WorktreeNameSanitizer.trimForSubmit(WorktreeNameSanitizer.sanitize(value))
    }
}
