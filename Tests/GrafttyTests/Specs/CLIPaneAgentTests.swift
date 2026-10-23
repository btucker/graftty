import Foundation
import ArgumentParser
import Testing
@testable import Graftty
@testable import GrafttyCLI
@testable import GrafttyKit

@Suite("CLI pane add agent launch")
struct CLIPaneAgentTests {
    @Test("@spec ATTN-1.24: When `graftty pane add` is invoked with `--agent <codex|claude>`, the CLI shall request an agent launch in the new pane with the initial task from `--prompt` or `--prompt-stdin`, and shall reject a prompt flag without `--agent`, both prompt flags together, `--agent` with `--command`, and an unknown runtime.")
    func agentFlagsBuildAgentRequest() throws {
        let command = try PaneAdd.parse(["review-wt", "--agent", "codex", "--prompt", "Review the diff"])
        let request = command.request(path: "/repo/.worktrees/review-wt", resolvedPrompt: "Review the diff")
        #expect(request == .addPane(path: "/repo/.worktrees/review-wt", direction: .right, command: nil,
                                    agentRuntime: .codex, agentPrompt: "Review the diff"))

        _ = try PaneAdd.parse(["--agent", "claude", "--prompt-stdin"])
        for invalid in [
            ["--prompt", "x"],
            ["--prompt-stdin"],
            ["--agent", "codex", "--prompt", "x", "--prompt-stdin"],
            ["--agent", "codex", "--command", "codex"],
            ["--agent", "gemini"],
        ] {
            #expect(throws: (any Error).self) { _ = try PaneAdd.parse(invalid) }
        }
    }

    @Test("@spec ATTN-1.27: If an add-pane request carries an agent prompt without an agent runtime, or an agent runtime together with a command, then the application shall reject it before splitting a pane.")
    func appRejectsInvalidAgentPaneRequests() {
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: nil, command: nil, agentPrompt: "x") != nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: .codex, command: "codex", agentPrompt: nil) != nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: .codex, command: nil, agentPrompt: "x") == nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: nil, command: "pnpm test", agentPrompt: nil) == nil)
    }

    @Test("@spec ATTN-1.28: When a pane added with `graftty pane add --agent` is destroyed, the application shall delete that pane's staged agent prompt file and withdraw its pending durable initial task, so a pane closed before its agent starts leaves no task behind for the next agent of that runtime.")
    @MainActor
    func destroyedPaneRunsStagedLaunchCleanup() {
        let manager = TerminalManager(socketPath: "/tmp/graftty-pane-prompt-test.sock")
        let pane = PaneSlotID()
        var cleanups = 0
        manager.trackStagedLaunch(for: pane) { cleanups += 1 }

        manager.destroySurface(terminalID: PaneSlotID())
        #expect(cleanups == 0)
        manager.destroySurface(terminalID: pane)
        #expect(cleanups == 1)
        manager.destroySurface(terminalID: pane)
        #expect(cleanups == 1)
    }

    @Test("`graftty pane add --help` documents --agent, --prompt-stdin, and exact-ID addressing")
    func helpDocumentsAgentLaunch() {
        let help = PaneAdd.helpMessage()
        #expect(help.contains("--agent"))
        #expect(help.contains("--prompt-stdin"))
        #expect(help.contains("only when no other agent of that runtime"))
    }

    @Test("A plain `pane add --command` request carries no agent fields")
    func commandRequestHasNoAgent() throws {
        let command = try PaneAdd.parse(["--command", "pnpm test"])
        let request = command.request(path: "/wt", resolvedPrompt: nil)
        #expect(request == .addPane(path: "/wt", direction: .right, command: "pnpm test"))
    }
}
