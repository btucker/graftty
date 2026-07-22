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
        let launchCommand = WorktreeAgentLaunchCommand.build(
            agent: agent,
            prompt: resolvedPrompt,
            exactCommand: command
        )
        let callerWorktree = try CLIEnv.resolveWorktree()
        var response = try CLIEnv.sendRequest(.createWorktree(
            callerWorktree: callerWorktree,
            worktreeName: names.worktree,
            branchName: names.branch,
            existing: existing,
            command: launchCommand,
            agentRuntime: agent.flatMap { TeamHookRuntime(rawValue: $0) }
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

    private static func readPromptFromStdin() throws -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard let prompt = String(data: data, encoding: .utf8), !prompt.isEmpty else {
            throw ValidationError("--prompt-stdin requires a non-empty UTF-8 prompt")
        }
        return prompt
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

enum WorktreeAgentLaunchCommand {
    static func validationError(prompt: String?) -> String? {
        guard let prompt, prompt.utf8.contains(0) else { return nil }
        return "agent prompts cannot contain NUL bytes"
    }

    static func build(agent: String?, prompt: String?, exactCommand: String?) -> String? {
        if let exactCommand { return exactCommand }
        guard let agent else { return nil }
        guard let prompt else { return agent }
        // This string is typed through an interactive PTY, where control
        // bytes are interpreted by the terminal line editor before shell
        // quoting applies. Carry only printable base64 through the PTY and
        // decode after the shell accepts the line. The sentinel preserves
        // trailing newlines that command substitution would otherwise trim.
        let encoded = Data(prompt.utf8).base64EncodedString()
        let encodedLiteral = shellLiteral(encoded)
        return """
        ( _graftty_agent_prompt="$(/usr/bin/printf '%s' \(encodedLiteral) | /usr/bin/base64 -D; /usr/bin/printf x)"; _graftty_agent_prompt="${_graftty_agent_prompt%x}"; exec \(agent) -- "$_graftty_agent_prompt" )
        """
    }

    static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
