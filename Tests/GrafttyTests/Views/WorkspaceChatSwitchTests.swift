import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI
@testable import Graftty

@MainActor
struct WorkspaceChatSwitchTests {
    private func worktree(provider: TeamHookRuntime = .codex) -> (WorktreeEntry, PaneSlotID) {
        let slot = PaneSlotID()
        var entry = WorktreeEntry(path: "/repo/chat", branch: "chat", state: .running,
                                  splitTree: SplitTree(root: .leaf(slot)))
        var agent = ManagedAgent(name: "Agent", provider: provider, parent: nil)
        agent.paneSlotID = slot
        agent.providerSessionID = "thread-1"
        entry.agents = [agent]
        entry.paneSessions = [slot: PaneSessionID()]
        let group = WorkspaceLayout<PaneSlotID>.Group(sessions: [slot], selected: slot)
        entry.workspaceLayout = WorkspaceLayout(root: .group(group.id), groups: [group])
        entry.focusedPaneSlotID = slot
        return (entry, slot)
    }

    @Test("@spec AGENT-6.183: When a user switches a supported running agent tab between Chat and Terminal on Mac or GrafttyMobile, the application shall keep the same tab, terminal session, provider process, assignment, and conversation in both directions.")
    func switchingViewsKeepsTheTabItsSessionAndItsAgent() {
        let (original, slot) = worktree()
        var entry = original

        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry)
        #expect(entry.workspaceLayout?.showsChat(slot) == true)
        #expect(entry.agents == original.agents)
        #expect(entry.paneSessions == original.paneSessions)
        #expect(entry.splitTree == original.splitTree)
        #expect(entry.focusedPaneSlotID == original.focusedPaneSlotID)
        #expect(entry.workspaceLayout?.groups == original.workspaceLayout?.groups)

        WorkspaceChatSwitch.setView(chat: false, slot: slot, in: &entry)
        #expect(entry == original)
    }

    @Test("@spec AGENT-6.186: When a user switches views with unsent input, the application shall preserve each view's draft in its original input field without submitting it.")
    func eachViewKeepsItsOwnUnsentInput() {
        var (entry, slot) = worktree()
        let models = AgentChatModelStore<PaneSlotID>()
        models.model(for: slot).draft = "half-written prompt"

        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry)
        WorkspaceChatSwitch.setView(chat: false, slot: slot, in: &entry)
        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry)

        #expect(models.model(for: slot).draft == "half-written prompt")
        #expect(models.model(for: PaneSlotID()).draft.isEmpty)
        models.prune(keeping: [])
        #expect(models.model(for: slot).draft.isEmpty)
    }

    @Test func aTabShowingChatDoesNotTakeTheTerminalKeyboard() {
        var (entry, slot) = worktree()
        #expect(entry.showsNonTerminalContent(in: slot) == false)
        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry)
        #expect(entry.showsNonTerminalContent(in: slot))
        // An agent that can no longer offer Chat falls back to its terminal.
        entry.agents[0].providerSessionID = nil
        #expect(entry.showsNonTerminalContent(in: slot) == false)
    }

    @Test func selectingChatClearsTerminalFocusThroughItsWindow() {
        var (entry, slot) = worktree()
        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry)
        var clears = 0
        var focused: [PaneSlotID] = []
        let view = WorkspaceContentView(
            terminalManager: TerminalManager(socketPath: "/tmp/graftty-chat-window-focus-test.sock"),
            worktree: Binding(get: { entry }, set: { entry = $0 }),
            onFocusTerminal: { focused.append($0) }, onNewTerminal: {}, onCloseTerminal: { _ in },
            onClearFocus: { clears += 1 }
        )
        view.stageAgent(slot)
        #expect(clears == 1)
        #expect(focused.isEmpty)

        WorkspaceChatSwitch.setView(chat: false, slot: slot, in: &entry)
        view.stageAgent(slot)
        #expect(clears == 1)
        #expect(focused == [slot])
    }

    @Test func aTabThatCannotAttachStaysInTerminal() {
        var (entry, slot) = worktree(provider: .claude)
        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry)
        #expect(entry.workspaceLayout?.showsChat(slot) != true)
    }

}
