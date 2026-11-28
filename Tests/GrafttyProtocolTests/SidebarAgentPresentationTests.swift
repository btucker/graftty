import Testing
@testable import GrafttyProtocol

struct SidebarAgentPresentationTests {
    @Test("@spec LAYOUT-2.188: While a live agent is named on a gallery tile, a stage pane, or a sidebar logo, the application shall use its current terminal title, omit the provider's animated prefix, and fall back to its assignment name when the displayed title is blank.")
    func liveTitleTakesPrecedence() {
        #expect(SidebarAgentTitle.display(terminalTitle: "Investigating focus", agentName: "Review") == "Investigating focus")
        #expect(SidebarAgentTitle.display(terminalTitle: "Tests passing", agentName: "Review") == "Tests passing")
        #expect(SidebarAgentTitle.display(terminalTitle: "", agentName: "Review") == "Review")
        #expect(SidebarAgentTitle.display(terminalTitle: " \n", agentName: "Review") == "Review")
        #expect(SidebarAgentTitle.display(terminalTitle: "Legacy title", agentName: nil) == "Legacy title")
        for (provider, frames) in [("codex", "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"), ("claude", "◐◑")] {
            for frame in frames {
                #expect(SidebarAgentTitle.display(terminalTitle: "\(frame) Review", agentName: nil, tabProvider: provider) == "Review")
            }
        }
        #expect(SidebarAgentTitle.display(terminalTitle: "⠙ ", agentName: "⠙ My title", tabProvider: "codex") == "⠙ My title")
        #expect(SidebarAgentTitle.display(terminalTitle: "⠙ Review", agentName: nil) == "⠙ Review")
        #expect(SidebarAgentTitle.display(terminalTitle: "⠙Review", agentName: nil, tabProvider: "codex") == "⠙Review")
        #expect(SidebarAgentTitle.display(terminalTitle: "✳ Ready", agentName: nil, tabProvider: "claude") == "✳ Ready")
    }

    @Test func workspaceTabsUseCurrentTitleAndPreserveArchivedFallback() {
        func row(_ title: String?) -> WorktreePanes {
            WorktreePanes(path: "/repo", displayName: "repo", repoDisplayName: "repo", displayBranch: "main",
                state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil,
                layout: title.map { .leaf(sessionName: "codex", title: $0, attentionText: nil, isBusy: false, attentionSource: nil) },
                agents: [.init(id: "a", name: "Codex", provider: "codex", status: "running", sessionName: "codex")])
        }
        #expect(row("Investigating focus").workspaceSessionTitle("codex") == "Investigating focus")
        #expect(row("⠙ Investigating focus").workspaceSessionTitle("codex") == "Investigating focus")
        #expect(row("Tests passing").workspaceSessionTitle("codex") == "Tests passing")
        #expect(row(" \n").workspaceSessionTitle("codex") == "Codex")
        #expect(row(nil).workspaceSessionTitle("codex") == "Codex")
        #expect(row(nil).workspaceSessionTitle("missing") == "Terminal")
    }

}
