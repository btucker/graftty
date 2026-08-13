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
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.mainWorktree)
        #expect(prompt.contains("\"main\""))
        #expect(prompt.lowercased().contains("main worktree"))
        #expect(prompt.contains("acme-web"))
    }

    @Test func mainWorktreeVariantListsOtherWorktrees() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.mainWorktree)
        #expect(prompt.contains("\"feature/login\""))
        #expect(prompt.contains("\"feature/signup\""))
    }

    @Test func mainWorktreeVariantStatesStatusEventsRouteHere() {
        let view = makeView()
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: view.mainWorktree)
        #expect(prompt.contains("status events route here"))
    }

    @Test func nonMainVariantNamesMainWorktree() {
        let view = makeView()
        let me = view.members.first(where: { $0.name == "feature/login" })!
        let prompt = TeamInstructionsRenderer.render(team: view, viewer: me)
        #expect(prompt.contains("\"feature/login\""))
        #expect(prompt.contains("\"main\""))
        #expect(prompt.lowercased().contains("main worktree"))
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
        #expect(prompt.contains("Status events route there"))
    }

    @Test("""
    @spec TEAM-3.2: The complete built-in session template shall render a main-worktree variant when the viewer is the repository's main worktree and a linked-worktree variant otherwise. Both variants name the repository and viewer, identify the main worktree, and list the other linked worktrees from the template's dynamic `agent` and `team` context.
    """)
    func completeTemplateRendersBothViewerVariants() throws {
        let view = makeView()
        let linkedViewer = try #require(
            view.members.first(where: { $0.name == "feature/login" })
        )
        let main = TeamInstructionsRenderer.render(
            team: view,
            viewer: view.mainWorktree
        )
        let linked = TeamInstructionsRenderer.render(
            team: view,
            viewer: linkedViewer
        )

        #expect(main.contains(#"You are "main" on branch `main` in repo "acme-web"."#))
        #expect(main.contains("Worktree: `/r/acme`."))
        #expect(main.contains("This is the main worktree; status events route here."))
        #expect(main.contains("\"feature/login\""))
        #expect(linked.contains("Worktree: `/r/acme/.worktrees/feature-login`."))
        #expect(linked.contains(#"Main worktree: "main" on `main` at `/r/acme`."#))
        #expect(linked.contains("Status events route there."))
        #expect(linked.contains("\"feature/signup\""))
    }

    @Test func promptsAvoidLegacyRoleTerminology() {
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
        let mainPrompt = TeamInstructionsRenderer.render(team: view, viewer: view.mainWorktree)
        let linkedMember = view.members.first(where: { $0.name == "feature/login" })!
        let linkedPrompt = TeamInstructionsRenderer.render(team: view, viewer: linkedMember)
        for prompt in [mainPrompt, linkedPrompt] {
            #expect(!prompt.contains("MUST proactively"))
            #expect(!prompt.contains("You should "))   // case-sensitive "You should" sentence-start
            #expect(!prompt.contains("you should "))
        }
    }

    @Test func defaultTemplateIsTheCompleteVisibleSessionPrompt() {
        let template = TeamInstructionsRenderer.defaultTemplate

        #expect(template.contains("Graftty team context."))
        #expect(template.contains("graftty worktree add <name> --agent <codex|claude>"))
        #expect(template.contains("graftty worktree remove <worktree> [--force]"))
        #expect(template.contains("--base <ref>"))
        #expect(template.contains("graftty team send --stdin"))
        #expect(template.contains("marks displayed rows read after successful output"))
        #expect(template.contains("--keep-unread"))
        #expect(template.contains("--unread` is an alias"))
        #expect(template.contains("--history"))
        #expect(template.contains("diagnostic peeks"))
        #expect(template.contains("Never edit Graftty state files"))
        #expect(template.contains("do not poll"))
        #expect(template.contains(#"{{ agent.name }}"#))
        #expect(template.contains(#"{{ agent.branch }}"#))
        #expect(template.contains(#"{{ team.repo }}"#))
        #expect(template.contains("{% for worktree in team.other_worktrees %}"))
    }

    @Test("""
    @spec INSTR-6.4: When the built-in team session prompt is rendered, the application shall explain the hierarchical repository and worktree instruction-file forms, per-path Application Support/current-worktree/main-checkout precedence, current-filesystem reads, safe-file exclusions, peer-visible role descriptions, when an agent may suggest or author a file, and how to place an exact-worktree file where a child can receive it in its first and later sessions.
    """)
    func defaultTemplateExplainsInstructionFileAuthoring() {
        let template = TeamInstructionsRenderer.defaultTemplate

        #expect(template.contains(".graftty/GRAFTTY.md"))
        #expect(template.contains(".graftty/<parent>/<leaf>/GRAFTTY.md"))
        #expect(template.contains("path relative to the main checkout's `.worktrees/`"))
        #expect(template.contains("main checkout's key is the repository's default branch"))
        #expect(template.contains(
            "If Graftty cannot resolve the default branch"
        ))
        #expect(template.contains(
            "main checkout receives only `.graftty/GRAFTTY.md`"
        ))
        #expect(template.contains("shared with peers"))
        #expect(template.contains("matching scope"))
        #expect(template.contains(
            "~/Library/Application Support/Graftty/.graftty"
        ))
        #expect(template.contains("this worktree's `.graftty`"))
        #expect(template.contains("then the main checkout's `.graftty`"))
        #expect(template.contains("Application Support overlay is machine-wide"))
        #expect(template.contains("reads current filesystem bytes"))
        #expect(template.contains("does not inspect Git"))
        #expect(template.contains("staging or committing is not required"))
        #expect(template.contains("evicted iCloud placeholders are ignored"))
        #expect(template.contains("create its exact-worktree `GRAFTTY.md` where its first session can see it"))
        #expect(template.contains(
            "graftty worktree add <name> --base HEAD --agent <codex|claude>"
        ))
        #expect(template.contains("its own `.graftty` can tune later sessions"))
        #expect(template.contains("suggest an appropriate instruction file"))
        #expect(template.contains("only when authorized"))
    }

    @Test func defaultRenderIncludesSharedCommandsExactlyOnce() {
        let view = makeView()
        for member in view.members {
            let prompt = TeamInstructionsRenderer.render(team: view, viewer: member)
            #expect(prompt.components(separatedBy: "graftty team inbox").count - 1 == 1)
            #expect(prompt.components(separatedBy: "graftty team list").count - 1 == 1)
            #expect(prompt.contains("<graftty-peer-message agent=\"<exact-address>\" fallback-agent=\"<runtime-address>\">"))
            #expect(prompt.contains("<canonical-worktree-path>#<runtime>"))
            #expect(prompt.contains("display metadata and may be truncated"))
            #expect(!prompt.lowercased().contains("untrusted peer"))
        }
    }

    @Test func customTemplateCanUseFullSessionContext() throws {
        let view = makeView()
        let me = try #require(view.members.first(where: { $0.name == "feature/login" }))
        let prompt = try #require(TeamInstructionsRenderer.render(
            template: """
            {{ agent.name }} on {{ agent.branch }} in {{ team.repo }}
            main={{ team.main_worktree.worktree }}
            {% for worktree in team.other_worktrees %}peer={{ worktree.branch }}
            {% empty %}no peers
            {% endfor %}
            """,
            team: view,
            viewer: me
        ))

        #expect(prompt.contains("feature/login on feature/login in acme-web"))
        #expect(prompt.contains("main=/r/acme"))
        #expect(prompt.contains("peer=feature/signup"))
        #expect(!prompt.contains("peer=feature/login"))
    }
}
