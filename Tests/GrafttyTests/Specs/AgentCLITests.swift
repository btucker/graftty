import Foundation
import ArgumentParser
import Testing
@testable import GrafttyCLI
import GrafttyKit

struct AgentCLITests {
    @Test("@spec AGENT-6.72: When invoking agent add, the CLI shall accept an optional existing worktree and provider, preserve the prompt, and reject conflicting prompt sources or an unsupported provider.")
    func creationArguments() throws {
        let command = try AgentAdd.parse(["review", "--worktree", "current", "--provider", "claude", "--prompt-stdin"])
        #expect(command.worktree == "current")
        #expect(command.provider == "claude")
        #expect(command.promptStdin)
        let defaultCommand = try AgentAdd.parse(["new-work"])
        #expect(defaultCommand.worktree == nil)
        #expect(defaultCommand.provider == nil)
        for args in [["a", "--provider", "unknown"], ["a", "--prompt", "x", "--prompt-stdin"], ["a", "--worktree", "w", "--base", "main"]] {
            #expect(throws: (any Error).self) { _ = try AgentAdd.parse(args) }
        }
        #expect(GrafttyCLI.helpMessage().contains("agent"))
    }

    @Test("@spec AGENT-6.73: When invoking agent close, the CLI shall require the completion identity so cleanup cannot target a newer assignment by accident.")
    func closeRequiresCompletion() throws {
        let id = UUID().uuidString
        let command = try AgentClose.parse(["codex-123456789abc", "--completion", id])
        #expect(command.completion == id)
        #expect(throws: (any Error).self) { _ = try AgentClose.parse(["codex-123456789abc"]) }
        #expect(throws: (any Error).self) { _ = try AgentClose.parse(["codex-123456789abc", "--completion", "wrong"]) }
    }
}
