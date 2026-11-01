import Foundation
import ArgumentParser
import Testing
@testable import GrafttyCLI
import GrafttyKit
import GrafttyProtocol

struct AgentCLITests {
    @Test("@spec AGENT-6.127: When invoking agent add, the CLI shall launch in the background by default and accept --select-tab to explicitly select the new agent.")
    func explicitAgentTabSelection() throws {
        #expect(try AgentAdd.parse(["review", "--select-tab"]).selectTab)
        #expect(try !AgentAdd.parse(["review"]).selectTab)
        #expect(AgentAdd.helpMessage().contains("--select-tab"))
    }

    @Test("@spec AGENT-6.114: When reconstructing agent details, the CLI shall reject changed or missing snapshot identities, mismatched managed IDs, and noncontiguous chunks instead of combining revisions.")
    func detailReaderValidatesSnapshotIdentity() throws {
        let agent = ManagedAgent(name: "Archive", provider: .codex, parent: nil)
        let bytes = try JSONEncoder().encode(agent)
        let split = bytes.count / 2
        let token = UUID()
        let request = AgentControlRequest(action: .show, callerWorktree: "/repo", agentID: agent.id)
        var calls = 0
        let actual = try AgentCLI.readDetails(request) { request in
            calls += 1
            if calls == 1 {
                return [.init(worktree: "/repo", agent: agent.summary(), detail: bytes.prefix(split),
                              nextOffset: split, detailToken: token)]
            }
            #expect(request.offset == split && request.detailToken == token)
            return [.init(worktree: "/repo", agent: agent.summary(), detail: bytes.dropFirst(split), detailToken: token)]
        }
        #expect(actual == bytes)
        for failure in 0..<4 {
            var calls = 0
            #expect(throws: (any Error).self) {
                _ = try AgentCLI.readDetails(request) { _ in
                    calls += 1
                    if calls == 1 {
                        return [.init(worktree: "/repo", agent: agent.summary(), detail: bytes.prefix(split),
                                      nextOffset: split, detailToken: token)]
                    }
                    let responseAgent = failure == 2 ? ManagedAgent(name: "Replacement", provider: .codex, parent: nil) : agent
                    return [.init(worktree: "/repo", agent: responseAgent.summary(), detail: bytes.dropFirst(split),
                                  nextOffset: failure == 3 ? split - 1 : nil,
                                  detailToken: failure == 0 ? UUID() : failure == 1 ? nil : token)]
                }
            }
        }
    }
    @Test("@spec AGENT-6.96: When an agent command runs after changing directory, the CLI shall resolve its owning terminal session before its current directory and retain explicit cross-project pane launch compatibility.")
    func callerUsesOwningSessionBeforeCWD() throws {
        let slot = PaneSlotID()
        let session = PaneSessionID()
        var owner = WorktreeEntry(path: "/repo/assigned", branch: "assigned", state: .running)
        owner.paneSessions[slot] = session
        let sibling = WorktreeEntry(path: "/repo/other", branch: "other")
        let foreign = WorktreeEntry(path: "/foreign", branch: "main")
        let state = AppState(repos: [RepoEntry(path: "/repo", displayName: "repo", worktrees: [owner, sibling]),
            RepoEntry(path: "/foreign", displayName: "foreign", worktrees: [foreign])])
        let name = ZmxLauncher.sessionName(for: session)
        #expect(try AgentCLI.callerWorktree(state: state, paneSessionName: name, cwdWorktree: { sibling.path }) == owner.path)
        #expect(try AgentCLI.callerWorktree(targetFallback: foreign.path, state: state,
            paneSessionName: name, cwdWorktree: { sibling.path }) == foreign.path)
        #expect(try AgentCLI.callerWorktree(targetFallback: owner.path, state: state,
            paneSessionName: nil, cwdWorktree: { throw CLIError.notInsideWorktree }) == owner.path)
    }

    @Test("@spec AGENT-6.97: When invoking agent show, the CLI shall require an exact managed ID and expose paged summary listing separately from full retained details.")
    func detailAndPageArguments() throws {
        #expect(try AgentShow.parse(["codex-123456789abc", "--json"]).json)
        #expect(throws: (any Error).self) { _ = try AgentShow.parse([]) }
        let list = try AgentList.parse(["--offset", "100", "--limit", "25", "--json"])
        #expect(list.offset == 100 && list.limit == 25)
        #expect(throws: (any Error).self) { _ = try AgentList.parse(["--limit", "201"]) }
    }
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
