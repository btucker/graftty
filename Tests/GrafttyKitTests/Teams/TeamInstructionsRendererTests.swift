import Testing
@testable import GrafttyKit

@Suite("TeamInstructionsRenderer Tests")
struct TeamInstructionsRendererTests {

    private func makeView() -> TeamView {
        var repo = RepoEntry(path: "/r/acme", displayName: "acme-web")
        repo.worktrees.append(WorktreeEntry(path: "/r/acme", branch: "main"))
        repo.worktrees.append(WorktreeEntry(path: "/r/acme/.worktrees/feature-login", branch: "feature/login"))
        repo.worktrees.append(WorktreeEntry(path: "/r/acme/.worktrees/feature-signup", branch: "feature/signup"))
        return TeamView.team(for: repo.worktrees[0], in: [repo], teamsEnabled: true)!
    }

    @Test func mainWorktreeVariantNamesItself() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        #expect(prompt.contains("\"main\""))
        #expect(prompt.contains("main worktree"))
        #expect(prompt.contains("acme-web"))
    }

    @Test func mainWorktreeVariantListsOtherWorktrees() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        #expect(prompt.contains("\"feature/login\""))
        #expect(prompt.contains("\"feature/signup\""))
    }

    @Test func mainWorktreeVariantDocumentsTeamEvents() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        #expect(prompt.contains("team_member_joined"))
        #expect(prompt.contains("team_member_left"))
        #expect(prompt.contains("team_message"))
        #expect(prompt.contains("pr_state_changed"))
        #expect(prompt.contains("ci_conclusion_changed"))
        #expect(prompt.contains("merge_state_changed"))
        #expect(!prompt.contains("team_pr_merged"))
    }

    @Test func nonMainVariantNamesMainWorktree() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature/login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        #expect(prompt.contains("\"feature/login\""))
        #expect(prompt.contains("\"main\""))
        #expect(prompt.contains("main worktree"))
    }

    @Test func nonMainVariantListsOtherWorktrees() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature/login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        #expect(prompt.contains("\"feature/signup\""))
    }

    @Test func nonMainVariantStatesStatusEventsRouteToMainWorktree() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature/login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        #expect(prompt.contains("Status events route to the main worktree"))
    }

    @Test func promptsAvoidLeadCoworkerTerminology() {
        let view = makeView()
        let prompts = view.members.map { TeamInstructionsRenderer.render(team: view, viewer: $0).lowercased() }
        for prompt in prompts {
            #expect(!prompt.contains("lead"))
            #expect(!prompt.contains("coworker"))
        }
    }

    @Test func neitherVariantPrescribesPolicy() {
        // Cleanup verification: prompts describe mechanism only, no "you must…" / "you should…"
        let view = makeView()
        let leadPrompt = TeamInstructionsRenderer.render(team: view, viewer: view.lead)
        let cw = view.members.first(where: { $0.name == "feature/login" })!
        let cwPrompt = TeamInstructionsRenderer.render(team: view, viewer: cw)
        for prompt in [leadPrompt, cwPrompt] {
            #expect(!prompt.contains("MUST proactively"))
            #expect(!prompt.contains("You should "))   // case-sensitive "You should" sentence-start
            #expect(!prompt.contains("you should "))
        }
    }
}
