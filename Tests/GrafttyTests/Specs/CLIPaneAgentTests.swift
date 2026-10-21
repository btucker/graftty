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
        guard case .addPane(let path, let direction, let shell, let runtime, let prompt) = request else {
            Issue.record("Expected .addPane")
            return
        }
        #expect(path == "/repo/.worktrees/review-wt")
        #expect(direction == .right)
        #expect(shell == nil)
        #expect(runtime == .codex)
        #expect(prompt == "Review the diff")

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

    @Test("@spec ATTN-1.27: If an add-pane request carries an agent prompt without an agent runtime, an agent runtime together with a command, or an agent runtime while Agent Teams is disabled, then the application shall reject it before splitting a pane.")
    func appRejectsInvalidAgentPaneRequests() {
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: nil, command: nil, agentPrompt: "x", teamsEnabled: true) != nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: .codex, command: "codex", agentPrompt: nil, teamsEnabled: true) != nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: .codex, command: nil, agentPrompt: "x", teamsEnabled: false) != nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: .codex, command: nil, agentPrompt: "x", teamsEnabled: true) == nil)
        #expect(CLIWorktreeCreationPolicy.paneAddError(
            agentRuntime: nil, command: "pnpm test", agentPrompt: nil, teamsEnabled: false) == nil)
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
        guard case .addPane(_, _, let shell, let runtime, let prompt) = request else {
            Issue.record("Expected .addPane")
            return
        }
        #expect(shell == "pnpm test")
        #expect(runtime == nil)
        #expect(prompt == nil)
    }
}
