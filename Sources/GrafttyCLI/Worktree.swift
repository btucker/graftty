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
        let launch = try WorktreeAgentLaunchCommand.prepare(
            agent: agent.flatMap { TeamHookRuntime(rawValue: $0) },
            prompt: resolvedPrompt,
            exactCommand: command
        )
        var operationOwnsPromptFile = false
        defer {
            if !operationOwnsPromptFile {
                launch.discardPromptFile()
            }
        }
        let callerWorktree = try CLIEnv.resolveWorktree()
        var response = try CLIEnv.sendRequest(.createWorktree(
            callerWorktree: callerWorktree,
            worktreeName: names.worktree,
            branchName: names.branch,
            existing: existing,
            command: launch.command,
            agentRuntime: agent.flatMap { TeamHookRuntime(rawValue: $0) }
        ))
        if case .worktreeCreate = response {
            // The app may still be running Git after this CLI exits or times
            // out. The short launch command now owns the staged file and
            // removes it after reading; a future launch prunes abandoned
            // files left by terminal or Git failures.
            operationOwnsPromptFile = true
        }
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

struct PreparedWorktreeAgentLaunch {
    let command: String?
    let promptFile: URL?

    func discardPromptFile(fileManager: FileManager = .default) {
        guard let promptFile else { return }
        try? fileManager.removeItem(at: promptFile)
    }
}

enum WorktreeAgentLaunchCommand {
    /// An agent launched with no user task still needs one completed turn:
    /// Claude installs its async inbox watcher from the Stop hook. Without
    /// this bootstrap, a message sent after SessionStart can remain queued
    /// forever in an untouched session.
    static let bootstrapPrompt = """
    This Graftty agent session was launched without a user task. During this initial turn, check for any Graftty team messages included in the session context and act on them. If there are none, briefly report that the session is ready, then wait for a task.
    """

    static func validationError(prompt: String?) -> String? {
        guard let prompt, prompt.utf8.contains(0) else { return nil }
        return "agent prompts cannot contain NUL bytes"
    }

    static func prepare(
        agent: TeamHookRuntime?,
        prompt: String?,
        exactCommand: String?,
        promptDirectory: URL = AppState.defaultDirectory
            .appendingPathComponent("agent-launch-prompts", isDirectory: true),
        fileManager: FileManager = .default,
        now: Date = Date()
    ) throws -> PreparedWorktreeAgentLaunch {
        if let exactCommand {
            return PreparedWorktreeAgentLaunch(command: exactCommand, promptFile: nil)
        }
        guard let agent else {
            return PreparedWorktreeAgentLaunch(command: nil, promptFile: nil)
        }

        try fileManager.createDirectory(
            at: promptDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        pruneStalePromptFiles(in: promptDirectory, fileManager: fileManager, now: now)

        let promptFile = promptDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("prompt")
        let initialTask = prompt.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        } ?? bootstrapPrompt
        guard fileManager.createFile(
            atPath: promptFile.path,
            contents: Data(initialTask.utf8),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [NSFilePathErrorKey: promptFile.path]
            )
        }

        // Keep the line typed through the PTY small and independent of the
        // task. In particular, nested heredocs, control bytes, and large
        // prompts never reach the interactive shell's edit buffer. The
        // sentinel preserves trailing newlines normally stripped by command
        // substitution. The file is removed before the runtime starts.
        let fileLiteral = shellLiteral(promptFile.path)
        let command = """
        ( _graftty_agent_prompt_file=\(fileLiteral); _graftty_agent_prompt="$(/bin/cat "$_graftty_agent_prompt_file"; _graftty_status=$?; /usr/bin/printf x; exit "$_graftty_status")" && /bin/rm -f "$_graftty_agent_prompt_file" && _graftty_agent_prompt="${_graftty_agent_prompt%x}" && exec \(agent.rawValue) -- "$_graftty_agent_prompt" )
        """
        return PreparedWorktreeAgentLaunch(command: command, promptFile: promptFile)
    }

    static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func pruneStalePromptFiles(
        in directory: URL,
        fileManager: FileManager,
        now: Date
    ) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-24 * 60 * 60)
        for file in files where file.pathExtension == "prompt" {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
