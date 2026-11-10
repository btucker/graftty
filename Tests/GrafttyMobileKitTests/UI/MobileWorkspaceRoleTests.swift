import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyMobileKit

@MainActor
struct MobileWorkspaceRoleTests {
    private func row(identifiesAgent: Bool) -> WorktreePanes {
        .init(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
              state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
              layout: .leaf(sessionName: "agent-session", title: "Codex", attentionText: nil,
                            isBusy: false, attentionSource: nil),
              agents: identifiesAgent ? [.init(id: "agent", name: "Agent", provider: "codex",
                                               status: "running", sessionName: "agent-session")] : [])
    }

    @Test("@spec IPAD-2.29: When mobile receives agent metadata after discovering its live terminal session, the application shall move the session into agent tabs without changing its identity, close an emptied terminal drawer, and preserve explicit user placement in the drawer across updates and restoration.")
    func lateAgentMetadataCorrectsAutomaticDrawerPlacement() throws {
        let suite = "MobileWorkspaceRoles-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID()
        var store = MobileWorkspaceStore(defaults: defaults)
        let initial = row(identifiesAgent: false)
        store.synchronize(hostID: host, worktree: initial, focused: "agent-session")
        #expect(store.layout(hostID: host, worktree: initial).terminals == ["agent-session"])
        store = MobileWorkspaceStore(defaults: defaults)

        let identified = row(identifiesAgent: true)
        store.synchronize(hostID: host, worktree: identified, focused: "agent-session", revealFocused: false)
        let layout = store.layout(hostID: host, worktree: identified)
        #expect(layout.group(containing: "agent-session")?.selected == "agent-session")
        #expect(layout.terminals.isEmpty)
        #expect(layout.sessions == ["agent-session"])
        #expect(layout.focusedSession == "agent-session")
        #expect(!layout.drawerVisible)
        let restored = MobileWorkspaceStore(defaults: defaults)
        restored.synchronize(hostID: host, worktree: identified, focused: "agent-session")
        #expect(restored.layout(hostID: host, worktree: identified) == layout)

        store.update(hostID: host, worktree: identified) { $0.moveToDrawer("agent-session") }
        store.synchronize(hostID: host, worktree: identified, focused: "agent-session", revealFocused: false)
        #expect(store.layout(hostID: host, worktree: identified).terminals == ["agent-session"])
        let manuallyPlaced = MobileWorkspaceStore(defaults: defaults)
        manuallyPlaced.synchronize(hostID: host, worktree: identified, focused: "agent-session")
        #expect(manuallyPlaced.layout(hostID: host, worktree: identified).terminals == ["agent-session"])
        #expect(manuallyPlaced.layout(hostID: host, worktree: identified).groups.isEmpty)
    }

    @Test("A refresh that temporarily omits agent metadata does not demote an existing agent tab")
    func metadataRefreshPreservesKnownAgentPlacement() throws {
        let suite = "MobileWorkspaceRoles-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID(), store = MobileWorkspaceStore(defaults: defaults)
        let identified = row(identifiesAgent: true)
        store.synchronize(hostID: host, worktree: identified, focused: "agent-session")
        let original = store.layout(hostID: host, worktree: identified)
        store.synchronize(hostID: host, worktree: row(identifiesAgent: false), focused: "agent-session", revealFocused: false)
        store.synchronize(hostID: host, worktree: identified, focused: "agent-session", revealFocused: false)
        #expect(store.layout(hostID: host, worktree: identified) == original)
    }

    @Test("Correcting a background session's role preserves the selected agent tab and hidden drawer")
    func backgroundRoleCorrectionDoesNotStealSelection() throws {
        let suite = "MobileWorkspaceRoles-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID(), store = MobileWorkspaceStore(defaults: defaults)
        let other = AgentSessionInfo(id: "other", name: "Other", provider: "codex", status: "running", sessionName: "other")
        let unidentified = row(identifiesAgent: false)
        let initial = unidentified.with(
            layout: .split(direction: .horizontal, ratio: 0.5,
                           left: try #require(unidentified.layout),
                           right: .leaf(sessionName: "other", title: "Other", attentionText: nil,
                                        isBusy: false, attentionSource: nil)), agents: [other])
        store.synchronize(hostID: host, worktree: initial, focused: "other")
        let identified = initial.with(agents: [other] + (row(identifiesAgent: true).agents ?? []))
        store.synchronize(hostID: host, worktree: identified, focused: "other", revealFocused: false)
        let layout = store.layout(hostID: host, worktree: identified)
        #expect(layout.group(containing: "other")?.selected == "other")
        #expect(layout.focusedSession == "other")
        #expect(layout.terminals.isEmpty)
        #expect(!layout.drawerVisible)
    }
}
