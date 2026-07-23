import Foundation
import Testing
@testable import Graftty
@testable import GrafttyCLI
import GrafttyKit

@Suite("CLI worktree creation and agent launch")
struct CLIWorktreeCreationTests {
    @Test("""
    @spec AGENT-5.1: When `graftty worktree add <name>` is invoked, the application shall create a linked worktree under the caller's tracked repository, open its first terminal pane, and wait for that pane's backend to accept any optional launch command before reporting success. `--existing` shall verify and reuse an exact local branch ref. `--agent codex|claude` shall queue that runtime as the pane's explicit initial command and shall stage prompt bytes outside the PTY before the shell reads them into one argument, while `--command` shall accept a generic initial command; `--agent` and `--command` are mutually exclusive.
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
            promptDirectory: root.appendingPathComponent("staged", isDirectory: true)
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

    @Test("""
    @spec AGENT-5.4: When `graftty worktree add --agent` has no non-empty user prompt, the application shall give the runtime a built-in initial task that checks session-start team context, completes one turn, and thereby establishes the runtime's idle-message wake path.
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
        #expect(!staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("NUL is rejected because POSIX argv cannot represent it")
    func promptRejectsNUL() {
        #expect(WorktreeAgentLaunchCommand.validationError(prompt: "a\0b") != nil)
        #expect(WorktreeAgentLaunchCommand.validationError(prompt: "") == nil)
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
