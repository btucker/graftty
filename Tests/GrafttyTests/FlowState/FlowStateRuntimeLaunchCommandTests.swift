import Foundation
import Testing
@testable import Graftty

@Suite("FlowState runtime launch commands")
struct FlowStateRuntimeLaunchCommandTests {
    @Test("Codex launch quotes workspace, socket, and bootstrap prompt safely")
    func codexCommandQuotesShellArguments() throws {
        let workspace = URL(fileURLWithPath: "/tmp/Graftty's State/flow-state/workspace")
        let promptFile = URL(fileURLWithPath: "/tmp/Graftty's State/flow-state/system-prompt.md")
        let command = FlowStateRuntimeLaunchCommand.build(
            runtime: .codex,
            workspaceURL: workspace,
            promptFileURL: promptFile,
            systemPrompt: "Preserve the human's flow",
            socketPath: "/tmp/graftty's.sock",
            capabilities: .init(codexSupportsSystemPromptConfig: false, claudeSupportsSystemPromptFile: true)
        )

        #expect(command.contains("GRAFTTY_SOCK='/tmp/graftty'\"'\"'s.sock'"))
        #expect(command.contains("codex --cd '/tmp/Graftty'\"'\"'s State/flow-state/workspace'"))
        #expect(command.contains("'Preserve the human'\"'\"'s flow'"))
    }

    @Test("Claude launch prefers a supported system prompt file")
    func claudeCommandUsesSystemPromptFile() throws {
        let workspace = URL(fileURLWithPath: "/tmp/flow-state/workspace")
        let promptFile = URL(fileURLWithPath: "/tmp/flow-state/system-prompt.md")
        let command = FlowStateRuntimeLaunchCommand.build(
            runtime: .claude,
            workspaceURL: workspace,
            promptFileURL: promptFile,
            systemPrompt: "unused inline prompt",
            socketPath: "/tmp/graftty.sock",
            capabilities: .init(codexSupportsSystemPromptConfig: false, claudeSupportsSystemPromptFile: true)
        )

        #expect(command == "cd '/tmp/flow-state/workspace' && GRAFTTY_SOCK='/tmp/graftty.sock' claude --system-prompt-file '/tmp/flow-state/system-prompt.md' --permission-mode manual --name 'Flow State'")
    }
}
