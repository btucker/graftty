import Foundation
import Testing
@testable import Graftty
@testable import GrafttyCLI
import GrafttyKit

@Suite("CLI worktree creation and agent launch")
struct CLIWorktreeCreationTests {
    @Test("""
    @spec AGENT-5.1: When `graftty worktree add <name>` is invoked, the application shall create a linked worktree under the caller's tracked repository, open its first terminal pane, and wait for that pane's backend to accept any optional launch command before reporting success. `--existing` shall verify and reuse an exact local branch ref. Before mutating an agent worktree, the CLI shall verify that the running app supports app-owned prompt staging, and the app shall reject obsolete file-owning prompt loaders. `--agent codex|claude` shall accept an initial prompt of at most 131072 UTF-8 bytes, send the prompt to the app, and queue that runtime as the pane's explicit initial command after the app stages the prompt outside the PTY; the loader shall run in a known POSIX shell even when the interactive shell is not POSIX. `--command` shall accept a generic initial command; `--agent` and `--command` are mutually exclusive.
    """)
    func helpDocumentsCreateAndLaunchWorkflow() throws {
        let help = WorktreeAdd.helpMessage()
        #expect(help.contains("--agent"))
        #expect(help.contains("--existing"))
        #expect(help.contains("--prompt-stdin"))
        #expect(help.contains("team send --stdin"))
    }

    @Test("Existing Git refs are preserved while the worktree directory name is normalized")
    func existingBranchNamesAreNotNormalized() {
        let names = WorktreeRequestNames.resolve(
            name: "Release Candidate",
            branch: "release--café-",
            existing: true
        )
        #expect(names.worktree == "Release-Candidate")
        #expect(names.branch == "release--café-")
    }

    @Test("Agent prompt size and shell syntax do not affect the bounded terminal command")
    func promptIsStagedOutsideTerminalTransport() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prompt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = """
        don't expand $(danger)\u{15}\r
        nested example:
          cat <<'INNER_TASK'
          echo "still prompt text"
          INNER_TASK
        \(String(repeating: "large prompt line\n", count: 2_000))
        """
        let prepared = try WorktreeAgentLaunchCommand.prepare(
            agent: .codex,
            prompt: prompt,
            exactCommand: nil,
            promptDirectory: root
        )
        let generated = try #require(prepared.command)
        let promptFile = try #require(prepared.promptFile)
        #expect(!generated.contains(prompt))
        #expect(generated.utf8.count < 1_024)
        #expect(generated.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        })
        #expect(try String(contentsOf: promptFile, encoding: .utf8) == prompt)
        let attributes = try FileManager.default.attributesOfItem(atPath: promptFile.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test("The staged prompt transport preserves control bytes, Unicode, and trailing newlines")
    func promptTransportRoundTripsExactly() throws {
        let prompt = "quote ' dollar $ backtick ` tab\t escape\u{1b}\r\nUnicode café\n\n"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try WorktreeAgentLaunchCommand.prepare(
            agent: .codex,
            prompt: prompt,
            exactCommand: nil,
            promptDirectory: root.appendingPathComponent("stage'd", isDirectory: true)
        )
        let command = try #require(prepared.command)
        let promptFile = try #require(prepared.promptFile)
        let fakeAgent = root.appendingPathComponent("codex")
        try "#!/bin/sh\n/usr/bin/printf '%s' \"$2\" | /usr/bin/base64\n"
            .write(to: fakeAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeAgent.path
        )

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": "\(root.path):/usr/bin:/bin"]
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        let encoded = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Data(base64Encoded: encoded) == Data(prompt.utf8))
        #expect(!FileManager.default.fileExists(atPath: promptFile.path))
    }

    @Test("The staged prompt loader works from a non-POSIX interactive shell")
    func promptTransportDoesNotDependOnInteractiveShellSyntax() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-tcsh-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = "nested <<'TASK' $(literal) café\n"
        let prepared = try WorktreeAgentLaunchCommand.prepare(
            agent: .codex,
            prompt: prompt,
            exactCommand: nil,
            promptDirectory: root.appendingPathComponent("stage'd", isDirectory: true)
        )
        let command = try #require(prepared.command)
        let fakeAgent = root.appendingPathComponent("codex")
        try "#!/bin/sh\n/usr/bin/printf '%s' \"$2\"\n"
            .write(to: fakeAgent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeAgent.path
        )

        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/tcsh")
        process.arguments = ["-fc", command]
        process.environment = ["PATH": "\(root.path):/usr/bin:/bin"]
        process.standardOutput = stdout
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ) == prompt)
    }

    @Test("Prompt staging tightens an existing launch directory to owner-only access")
    func promptDirectoryPermissionsAreTightened() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prompt-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: root.path
        )
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try WorktreeAgentLaunchCommand.prepare(
            agent: .codex,
            prompt: "task",
            exactCommand: nil,
            promptDirectory: root
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o700)
    }

    @Test("Preparing a second launch does not prune a prompt owned by a pending operation")
    func promptPruningIsAnExplicitRecoveryStep() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-prompt-pruning-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stalePrompt = root.appendingPathComponent("pending.prompt")
        try "still needed".write(to: stalePrompt, atomically: true, encoding: .utf8)
        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-25 * 60 * 60)],
            ofItemAtPath: stalePrompt.path
        )

        _ = try WorktreeAgentLaunchCommand.prepare(
            agent: .codex,
            prompt: "another task",
            exactCommand: nil,
            promptDirectory: root
        )
        #expect(FileManager.default.fileExists(atPath: stalePrompt.path))

        WorktreeAgentLaunchCommand.pruneStalePromptFiles(in: root, now: now)
        #expect(!FileManager.default.fileExists(atPath: stalePrompt.path))
    }

    @Test("""
    @spec AGENT-5.4: When `graftty worktree add --agent` has no non-empty user prompt, the application shall give the runtime a built-in initial task that reviews session-start team context under its untrusted-peer contract, completes one turn, and thereby establishes the runtime's idle-message wake path.
    """)
    func agentWithoutPromptStillGetsAnInitialTurn() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-bootstrap-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let prepared = try WorktreeAgentLaunchCommand.prepare(
            agent: .claude,
            prompt: nil,
            exactCommand: nil,
            promptDirectory: root
        )
        let promptFile = try #require(prepared.promptFile)
        let staged = try String(contentsOf: promptFile, encoding: .utf8)

        #expect(prepared.command?.contains("exec claude --") == true)
        #expect(staged.contains("team messages"))
        #expect(staged.contains("initial turn"))
        #expect(staged.contains("untrusted peer notes"))
        #expect(staged.contains("higher-priority instructions"))
        #expect(!staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("NUL is rejected because POSIX argv cannot represent it")
    func promptRejectsNUL() {
        #expect(WorktreeAgentLaunchCommand.validationError(prompt: "a\0b") != nil)
        #expect(WorktreeAgentLaunchCommand.validationError(prompt: "") == nil)
    }

    @Test("Oversized agent prompts are rejected before worktree mutation")
    func promptRejectsUnsafeArgumentSize() {
        let maximumBytes = 128 * 1_024
        #expect(WorktreeAgentLaunchCommand.validationError(
            prompt: String(repeating: "a", count: maximumBytes)
        ) == nil)
        #expect(WorktreeAgentLaunchCommand.validationError(
            prompt: String(repeating: "a", count: maximumBytes + 1)
        )?.contains("131072") == true)
    }

    @Test("Prompt stdin stops reading as soon as the byte limit is exceeded")
    func promptStdinReadIsBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-bounded-stdin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x61, count: WorktreeAgentLaunchCommand.maximumPromptBytes + 4_096)
            .write(to: root)
        let handle = try FileHandle(forReadingFrom: root)
        defer { try? handle.close() }

        #expect(throws: (any Error).self) {
            _ = try WorktreeAdd.readPromptFromStdin(fileHandle: handle)
        }
        #expect(try handle.offset() == UInt64(WorktreeAgentLaunchCommand.maximumPromptBytes + 1))
    }

    @Test("An exact command wins when no agent runtime is selected")
    func exactCommandPassesThrough() throws {
        let prepared = try WorktreeAgentLaunchCommand.prepare(
            agent: nil,
            prompt: nil,
            exactCommand: "my-agent --mode review"
        )
        #expect(prepared.command == "my-agent --mode review")
        #expect(prepared.promptFile == nil)
    }

    @Test("An explicit launch command suppresses the configured default command")
    func explicitLaunchDoesNotDoubleStartAnAgent() {
        #expect(defaultCommandDecision(
            defaultCommand: "claude",
            firstPaneOnly: false,
            isFirstPane: true,
            wasRehydrated: false,
            hasExplicitInitialInput: true
        ) == .skip)
    }

    @MainActor
    @Test("""
    @spec AGENT-5.2: While a CLI worktree-creation operation is retained, the application shall expose exactly one pending, ready, or failed state by operation ID, together with the canonical worktree path used as its stable messaging address.
    """)
    func creationStorePreservesAddressAcrossTransitions() {
        let store = CLIWorktreeCreationStore(terminalRetention: 60)
        let started = store.begin(
            worktreePath: "/repo/.worktrees/fix-auth",
            messageAddress: "/repo/.worktrees/fix-auth",
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(started.state == .pending)

        store.markReady(operationID: started.operationID, now: Date(timeIntervalSince1970: 101))
        let ready = store.status(operationID: started.operationID, now: Date(timeIntervalSince1970: 102))
        #expect(ready?.state == .ready)
        #expect(ready?.messageAddress == "/repo/.worktrees/fix-auth")
        #expect(ready?.worktreePath == "/repo/.worktrees/fix-auth")
    }

    @MainActor
    @Test("""
    @spec AGENT-5.5: Once the app accepts an agent worktree-creation request, it shall own the staged prompt until the terminal backend accepts the loader; if creation fails before then, the app shall remove the prompt. At startup it shall snapshot crash leftovers, prune expired files immediately, and remove the remaining snapshot after the recovery grace period without touching prompts created by current live operations.
    """)
    func creationFailureDiscardsStagedPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-failed-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let promptFile = root.appendingPathComponent("task.prompt")
        try "sensitive task".write(to: promptFile, atomically: true, encoding: .utf8)
        let store = CLIWorktreeCreationStore()
        let started = store.begin(
            worktreePath: "/repo/.worktrees/fix",
            messageAddress: "/repo/.worktrees/fix",
            stagedPromptFile: promptFile
        )

        store.markFailed(operationID: started.operationID, error: "git failed")

        #expect(!FileManager.default.fileExists(atPath: promptFile.path))
    }

    @MainActor
    @Test("A ready operation leaves prompt cleanup to the accepted shell command")
    func creationReadyTransfersStagedPromptToShell() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-ready-prompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let promptFile = root.appendingPathComponent("task.prompt")
        try "task".write(to: promptFile, atomically: true, encoding: .utf8)
        let store = CLIWorktreeCreationStore()
        let started = store.begin(
            worktreePath: "/repo/.worktrees/fix",
            messageAddress: "/repo/.worktrees/fix",
            stagedPromptFile: promptFile
        )

        store.markReady(operationID: started.operationID)

        #expect(FileManager.default.fileExists(atPath: promptFile.path))
    }

    @Test("Delayed crash recovery deletes only prompt files found at startup")
    func crashRecoverySnapshotExcludesCurrentOperations() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-crash-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let abandonedPrompt = root.appendingPathComponent("abandoned.prompt")
        try "prior process".write(to: abandonedPrompt, atomically: true, encoding: .utf8)
        let startupSnapshot = WorktreeAgentLaunchCommand.recoveryPromptFiles(in: root)

        let currentLaunch = try WorktreeAgentLaunchCommand.prepare(
            agent: .codex,
            prompt: "current operation",
            exactCommand: nil,
            promptDirectory: root
        )
        let currentPrompt = try #require(currentLaunch.promptFile)
        WorktreeAgentLaunchCommand.discardRecoveryPromptFiles(startupSnapshot)

        #expect(!FileManager.default.fileExists(atPath: abandonedPrompt.path))
        #expect(FileManager.default.fileExists(atPath: currentPrompt.path))
    }

    @Test("Agent launch is rejected before mutation when Agent Teams is disabled")
    func agentLaunchRequiresTeamMode() {
        #expect(CLIWorktreeCreationPolicy.validationError(
            agentRuntime: .codex,
            teamsEnabled: false
        )?.contains("Agent Teams is disabled") == true)
        #expect(CLIWorktreeCreationPolicy.validationError(
            agentRuntime: nil,
            teamsEnabled: false
        ) == nil)
    }

    @Test("The app stages current prompts and bare legacy launches, but preserves legacy loaders")
    func launchPolicyPreservesWireCompatibility() {
        #expect(CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
            agentRuntime: .codex,
            command: "codex",
            agentPrompt: "task"
        ))
        #expect(CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
            agentRuntime: .claude,
            command: "claude",
            agentPrompt: nil
        ))
        #expect(!CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
            agentRuntime: .codex,
            command: "( legacy-loader )",
            agentPrompt: nil
        ))
        #expect(!CLIWorktreeCreationPolicy.shouldStageAgentPrompt(
            agentRuntime: nil,
            command: "custom-command",
            agentPrompt: nil
        ))
    }

    @Test("The app rejects the obsolete file-owning loader but preserves released clients")
    func launchPolicyRejectsOnlyObsoleteStagedPromptLoaders() {
        let obsoleteLoader = """
        ( _graftty_agent_prompt_file='/tmp/task.prompt'; _graftty_agent_prompt="$(/bin/cat "$_graftty_agent_prompt_file")" && /bin/rm -f "$_graftty_agent_prompt_file" && exec codex -- "$_graftty_agent_prompt" )
        """
        #expect(CLIWorktreeCreationPolicy.obsoletePromptLoaderError(
            agentRuntime: .codex,
            command: obsoleteLoader,
            agentPrompt: nil
        ) != nil)
        #expect(CLIWorktreeCreationPolicy.obsoletePromptLoaderError(
            agentRuntime: .codex,
            command: "codex -- $(printf payload | base64 --decode)",
            agentPrompt: nil
        ) == nil)
        #expect(CLIWorktreeCreationPolicy.obsoletePromptLoaderError(
            agentRuntime: .codex,
            command: "codex",
            agentPrompt: "task"
        ) == nil)
    }

    @MainActor
    @Test("Terminal operation results expire but pending work does not")
    func creationStoreRetention() {
        let store = CLIWorktreeCreationStore(terminalRetention: 5)
        let started = store.begin(
            worktreePath: "/repo/.worktrees/fix",
            messageAddress: "fix",
            now: Date(timeIntervalSince1970: 100)
        )
        #expect(store.status(
            operationID: started.operationID,
            now: Date(timeIntervalSince1970: 1_000)
        )?.state == .pending)

        store.markFailed(
            operationID: started.operationID,
            error: "git failed",
            now: Date(timeIntervalSince1970: 1_001)
        )
        #expect(store.status(
            operationID: started.operationID,
            now: Date(timeIntervalSince1970: 1_007)
        ) == nil)
    }

    @Test("Injected instructions avoid persona language and document shell-safe prompting")
    func injectedInstructionsDocumentWorktreeAddressWorkflow() {
        let primer = TeamHookRenderer.teamProtocolPrimer_forTesting
        #expect(primer.contains("graftty worktree add <name> --agent codex"))
        #expect(primer.contains("worktree's stable message address"))
        #expect(primer.contains("graftty team send --stdin <address>"))
        #expect(primer.contains("--prompt-stdin"))
        #expect(!primer.contains("Spawn a teammate"))
    }
}
