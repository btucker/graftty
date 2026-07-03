import Foundation
import Testing
@testable import Graftty

@Suite("FlowState runtime launch commands")
struct FlowStateRuntimeLaunchCommandTests {
    @Test("Codex launch quotes workspace, socket, and bootstrap prompt safely")
    func codexCommandQuotesShellArguments() throws {
        let workspace = URL(fileURLWithPath: "/tmp/Graftty's State/flow-state/workspace")
        let promptFile = URL(fileURLWithPath: "/tmp/Graftty's State/flow-state/system-prompt.md")
        let launch = FlowStateRuntimeLaunchCommand.build(
            runtime: .codex,
            workspaceURL: workspace,
            promptFileURL: promptFile,
            systemPrompt: "Preserve the human's flow",
            socketPath: "/tmp/graftty's.sock",
            capabilities: .init(codexSupportsSystemPromptConfig: false, claudeSupportsSystemPromptFile: true)
        )

        #expect(launch.environment["GRAFTTY_SOCK"] == "/tmp/graftty's.sock")
        #expect(launch.promptMode == .bootstrapPrompt)
        #expect(launch.commandText.contains("GRAFTTY_SOCK='/tmp/graftty'\"'\"'s.sock'"))
        #expect(launch.commandText.contains("codex --cd '/tmp/Graftty'\"'\"'s State/flow-state/workspace'"))
        #expect(launch.commandText.contains("'Preserve the human'\"'\"'s flow'"))
    }

    @Test("Claude launch prefers a supported system prompt file")
    func claudeCommandUsesSystemPromptFile() throws {
        let workspace = URL(fileURLWithPath: "/tmp/flow-state/workspace")
        let promptFile = URL(fileURLWithPath: "/tmp/flow-state/system-prompt.md")
        let launch = FlowStateRuntimeLaunchCommand.build(
            runtime: .claude,
            workspaceURL: workspace,
            promptFileURL: promptFile,
            systemPrompt: "unused inline prompt",
            socketPath: "/tmp/graftty.sock",
            capabilities: .init(codexSupportsSystemPromptConfig: false, claudeSupportsSystemPromptFile: true)
        )

        #expect(launch.environment == ["GRAFTTY_SOCK": "/tmp/graftty.sock"])
        #expect(launch.promptMode == .systemPrompt)
        #expect(launch.commandText == "cd '/tmp/flow-state/workspace' && GRAFTTY_SOCK='/tmp/graftty.sock' claude --system-prompt-file '/tmp/flow-state/system-prompt.md' --permission-mode manual --name 'Flow State'")
    }

    @Test("Claude launch appends the system prompt when prompt files are unsupported")
    func claudeCommandAppendsSystemPromptWhenFileUnsupported() throws {
        let workspace = URL(fileURLWithPath: "/tmp/flow-state/workspace")
        let promptFile = URL(fileURLWithPath: "/tmp/flow-state/system-prompt.md")
        let launch = FlowStateRuntimeLaunchCommand.build(
            runtime: .claude,
            workspaceURL: workspace,
            promptFileURL: promptFile,
            systemPrompt: "Preserve the human's flow",
            socketPath: "/tmp/graftty.sock",
            capabilities: .init(codexSupportsSystemPromptConfig: false, claudeSupportsSystemPromptFile: false)
        )

        #expect(launch.promptMode == .appendSystemPrompt)
        #expect(launch.commandText == "cd '/tmp/flow-state/workspace' && GRAFTTY_SOCK='/tmp/graftty.sock' claude --append-system-prompt-file '/tmp/flow-state/system-prompt.md' --permission-mode manual --name 'Flow State'")
    }

    @Test("Codex launch keeps bootstrap prompt until a real config path is implemented")
    func codexCommandDoesNotDropPromptForUnimplementedConfigCapability() throws {
        let workspace = URL(fileURLWithPath: "/tmp/flow-state/workspace")
        let promptFile = URL(fileURLWithPath: "/tmp/flow-state/system-prompt.md")
        let launch = FlowStateRuntimeLaunchCommand.build(
            runtime: .codex,
            workspaceURL: workspace,
            promptFileURL: promptFile,
            systemPrompt: "Preserve focus",
            socketPath: "/tmp/graftty.sock",
            capabilities: .init(codexSupportsSystemPromptConfig: true, claudeSupportsSystemPromptFile: true)
        )

        #expect(launch.promptMode == .bootstrapPrompt)
        #expect(launch.commandText.contains("'Preserve focus'"))
    }
}
