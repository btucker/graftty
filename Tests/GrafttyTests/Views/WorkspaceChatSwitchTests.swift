import Testing
import GrafttyKit
import GrafttyProtocol
import GrafttyCommandUI
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

    @Test("@spec AGENT-6.169: When a user switches a supported running agent tab between Chat and Terminal on Mac or GrafttyMobile, the application shall keep the same tab, terminal session, provider process, assignment, and conversation in both directions.")
    func switchingViewsKeepsTheTabItsSessionAndItsAgent() {
        let (original, slot) = worktree()
        var entry = original

        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry, chatAvailable: true)
        #expect(entry.workspaceLayout?.showsChat(slot) == true)
        #expect(entry.agents == original.agents)
        #expect(entry.paneSessions == original.paneSessions)
        #expect(entry.splitTree == original.splitTree)
        #expect(entry.focusedPaneSlotID == original.focusedPaneSlotID)
        #expect(entry.workspaceLayout?.groups == original.workspaceLayout?.groups)

        WorkspaceChatSwitch.setView(chat: false, slot: slot, in: &entry, chatAvailable: true)
        #expect(entry == original)
    }

    @Test("@spec AGENT-6.172: When a user switches views with unsent input, the application shall preserve each view's draft in its original input field without submitting it.")
    func eachViewKeepsItsOwnUnsentInput() {
        var (entry, slot) = worktree()
        let models = AgentChatModelStore<PaneSlotID>()
        models.model(for: slot).draft = "half-written prompt"

        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry, chatAvailable: true)
        WorkspaceChatSwitch.setView(chat: false, slot: slot, in: &entry, chatAvailable: true)
        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry, chatAvailable: true)

        #expect(models.model(for: slot).draft == "half-written prompt")
        #expect(models.model(for: PaneSlotID()).draft.isEmpty)
        models.prune(keeping: [])
        #expect(models.model(for: slot).draft.isEmpty)
    }

    @Test func aTabThatCannotAttachStaysInTerminal() {
        var (entry, slot) = worktree(provider: .claude)
        WorkspaceChatSwitch.setView(chat: true, slot: slot, in: &entry, chatAvailable: false)
        #expect(entry.workspaceLayout?.showsChat(slot) != true)
    }

    @Test func availabilityIsRecheckedWhenTheConversationChanges() {
        var (entry, _) = worktree()
        let before = WorkspaceChatSwitch.availabilityKey(entry)
        entry.agents[0].providerSessionID = "thread-2"
        #expect(WorkspaceChatSwitch.availabilityKey(entry) != before)
    }
}
