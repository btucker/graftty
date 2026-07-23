import ArgumentParser
import Foundation
import GrafttyKit
import GrafttyProtocol

struct Worktree: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create worktrees and optionally launch agents in them",
        subcommands: [WorktreeAdd.self]
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
            existing: existing
        ) {
            throw ValidationError(error)
        }

        let resolvedPrompt = try promptStdin ? Self.readPromptFromStdin() : prompt
        if let error = WorktreeAgentLaunchCommand.validationError(prompt: resolvedPrompt) {
            throw ValidationError(error)
        }
        let agentRuntime = agent.flatMap { TeamHookRuntime(rawValue: $0) }
        if agentRuntime != nil {
            try Self.requireAgentPromptStagingCapability()
        }
        let callerWorktree = try CLIEnv.resolveWorktree()
        var response = try CLIEnv.sendRequest(.createWorktree(
            callerWorktree: callerWorktree,
            worktreeName: names.worktree,
            branchName: names.branch,
            existing: existing,
            // The capability check above guarantees the app will replace this
            // bare fallback with its staged loader before starting Git.
            command: command ?? agentRuntime?.rawValue,
            agentRuntime: agentRuntime,
            agentPrompt: resolvedPrompt
        ))
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

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
                    response = try CLIEnv.sendRequest(
                        .worktreeCreateStatus(operationID: operation.operationID)
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
            case .ok, .paneList, .paneShow, .teamList, .teamHookOutput, .teamInbox:
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

    private static func requireAgentPromptStagingCapability() throws {
        do {
            guard case .ok = try SocketClient.sendExpectingResponse(
                .agentPromptStagingCapability
            ) else {
                throw CLIError.socketError("unexpected capability response")
            }
        } catch let error as CLIError {
            switch error {
            case .socketTimeout, .socketError:
                CLIEnv.printError(
                    "the running Graftty app does not support safe agent prompt staging; quit and relaunch the updated app, then retry"
                )
            case .notInsideWorktree, .appNotRunning, .staleControlSocket, .socketPathTooLong:
                CLIEnv.printError(error.description)
            }
            throw ExitCode(1)
        } catch {
            CLIEnv.printError(
                "could not verify agent prompt staging support; quit and relaunch Graftty, then retry"
            )
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
