import Foundation
import Testing
@testable import Graftty
@testable import GrafttyCLI
import GrafttyKit

@Suite("CLI worktree creation and agent launch")
struct CLIWorktreeCreationTests {
    @Test("""
    @spec AGENT-5.1: When `graftty worktree add <name>` is invoked, the application shall create a linked worktree under the caller's tracked repository, open its first terminal pane, and wait for that pane's backend to accept any optional launch command before reporting success. `--existing` shall preserve and reuse a local branch name. `--agent codex|claude` shall queue that runtime as the pane's explicit initial command, while `--command` shall accept a generic initial command; `--agent` and `--command` are mutually exclusive.
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

    @Test("Agent prompts are POSIX-quoted before terminal injection")
    func promptIsShellQuoted() {
        let command = WorktreeAgentLaunchCommand.build(
            agent: "codex",
            prompt: "don't expand $(danger)",
            exactCommand: nil
        )
        #expect(command == "codex -- 'don'\\''t expand $(danger)'")
    }

    @Test("An exact command wins when no agent runtime is selected")
    func exactCommandPassesThrough() {
        #expect(WorktreeAgentLaunchCommand.build(
            agent: nil,
            prompt: nil,
            exactCommand: "my-agent --mode review"
        ) == "my-agent --mode review")
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
