import Testing
@testable import GrafttyProtocol

struct AgentCompletionSearchTests {
    private func candidate(_ name: String, project: String = "/repo") -> AgentCompletionCandidate {
        .init(address: "\(project)/\(name)#codex", projectPath: project,
              projectName: project == "/repo" ? "Graftty" : "Other Project",
              worktreePath: "\(project)/\(name)", worktreeName: name,
              hostName: "Build Mac", runtime: "codex")
    }

    @Test("@spec TEAM-15.18: When a user searches native completion, the application shall fuzzy-match ordered characters case-insensitively across worktree, project, host, provider and address fields, require every space-separated term, and rank compact and word-boundary matches above scattered matches within each project-priority group.")
    func fuzzySearch() {
        let compact = candidate("percent-complete")
        let scattered = candidate("previous-error-count")
        let unrelated = candidate("navigation")
        #expect(AgentCompletionCandidate.matching([scattered, compact, unrelated], query: "PCT", currentWorktreePath: nil) == [compact, scattered])
        #expect(AgentCompletionCandidate.matching([compact, unrelated], query: "pct gf BM cdx", currentWorktreePath: nil) == [compact])
        #expect(AgentCompletionCandidate.matching([compact], query: "xedoc", currentWorktreePath: nil).isEmpty)
        #expect(AgentCompletionCandidate.matching([compact], query: "pct missing", currentWorktreePath: nil).isEmpty)

        let boundary = candidate("fix-navigation")
        let middle = candidate("afixnavigation")
        #expect(AgentCompletionCandidate.matching([middle, boundary], query: "fn", currentWorktreePath: nil).first == boundary)
    }

    @Test("Current-project priority retains other projects and allows searching and selecting them")
    func allProjectsRemainSearchable() {
        let current = candidate("previous-error-count")
        let other = candidate("pct", project: "/other")
        let candidates = [other, current]
        #expect(AgentCompletionCandidate.matching(candidates, query: "pct", currentWorktreePath: current.worktreePath) == [current, other])
        #expect(AgentCompletionCandidate.matching(candidates, query: "oth pct", currentWorktreePath: current.worktreePath) == [other])
        #expect(AgentCompletionCandidate.matching(candidates, query: " ", currentWorktreePath: current.worktreePath) == [current, other])
    }
}
