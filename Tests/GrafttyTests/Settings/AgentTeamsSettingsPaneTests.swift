import Testing
import SwiftUI
import GrafttyKit
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test("""
    @spec TEAM-1.6: The Agent Teams Settings pane shall expose two user-editable Stencil-templated text areas backed by `@AppStorage` and registered into `UserDefaults.standard` at app startup so non-binding readers see the same defaults until the user overrides them. Clearing a field to the empty string disables that prompt. The first, `teamSessionPrompt`, shall visibly contain the complete built-in session-start context (`DefaultPrompts.sessionPrompt`), including the team protocol, commands, and role-specific text expressed with dynamic `agent` and `team` placeholders; its rendered value replaces, rather than follows, any hidden hard-coded primer. Its session context exposes `agent.name`, `agent.worktree`, `agent.branch`, `agent.running`, and `agent.main_worktree` plus `team.repo`, `team.repo_path`, `team.main_worktree`, `team.members`, and `team.other_worktrees`; legacy event-scoped `agent.this_worktree` and `agent.other_worktree` remain false. Queued inbox messages remain a separate transient hook section. A one-time migration shall preserve a legacy non-empty, renderable session suffix by appending it to the complete default template, shall back up and deactivate an invalid suffix so it cannot suppress the built-in context, and shall remove a legacy empty override so the registered complete default becomes visible. The second, `teamPrompt`, shall retain a non-empty compact automated-event default that renders the event body first, adds only event-specific actionable guidance, and omits generic delivery and same-worktree preambles; it shall render per recipient against the four event-scoped `agent` fields plus top-level `body` and `event` (`event.type`, `event.attrs`, `event.body`). Authored `team_message` rows bypass this event template and store no `agent_prompt`; automated events store rendered `agent_prompt` separately from their unchanged `body`. If an event template omits `{{ body }}`, the renderer appends it before rendering so older templates continue to surface event content. Hook delivery emits authored messages from raw `body`, automated events from `agent_prompt` when present, and otherwise falls through to `body`.
    """)
    func defaultPromptsAreVisibleAndEditable() {
        #expect(!DefaultPrompts.sessionPrompt.isEmpty)
        #expect(!DefaultPrompts.eventPrompt.isEmpty)
    }

    @Test func defaultSessionPromptIsTheCompleteHookTemplate() {
        let p = DefaultPrompts.sessionPrompt
        #expect(p.contains("Graftty team context."))
        #expect(p.contains("graftty team inbox"))
        #expect(p.contains("--base <ref>"))
        #expect(p.contains("Other linked worktrees:"))
        #expect(p.contains("status events route"))
        #expect(p.contains("agent.name"))
        #expect(p.contains("agent.branch"))
        #expect(p.contains("agent.main_worktree"))
        #expect(p.contains("team.main_worktree"))
        #expect(p.contains("team.other_worktrees"))
    }

    @Test func eventPromptIsCompactAndUsesEventContext() {
        let p = DefaultPrompts.eventPrompt
        #expect(p.contains("{{ body }}"))
        #expect(p.contains("event.type"))
        #expect(!p.contains("automated team event"))
        #expect(!p.lowercased().contains("this event is about"))
    }

    /// Catches Stencil syntax errors in the full session prompt for both
    /// viewer roles and in the per-event prompt across event agent shapes.
    @Test func defaultPromptsRenderUnderEveryAgentContext() {
        var repo = RepoEntry(path: "/r", displayName: "r")
        repo.worktrees.append(WorktreeEntry(path: "/r", branch: "main"))
        repo.worktrees.append(WorktreeEntry(path: "/r/alice", branch: "alice"))
        let team = TeamView.team(
            for: repo.worktrees[0],
            in: [repo],
            teamsEnabled: true
        )!
        for viewer in team.members {
            #expect(TeamInstructionsRenderer.render(
                template: DefaultPrompts.sessionPrompt,
                team: team,
                viewer: viewer
            ) != nil)
        }

        let shapes: [(isMainWorktree: Bool, thisWorktree: Bool, otherWorktree: Bool)] = [
            (true,  false, false),
            (false, true,  false),
            (false, false, true ),
            (false, false, false),
        ]
        for s in shapes {
            let ctx = EventBodyRenderer.makeAgentContext(
                branch: "b",
                isMainWorktree: s.isMainWorktree,
                thisWorktree: s.thisWorktree,
                otherWorktree: s.otherWorktree
            )
            #expect(EventBodyRenderer.renderAgentTemplate(
                DefaultPrompts.eventPrompt,
                agent: ctx,
                body: "PR #42 CI: pending → failure",
                event: [
                    "type": "ci_conclusion_changed",
                    "attrs": ["from": "pending", "to": "failure"],
                    "body": "PR #42 CI: pending → failure",
                ]
            ) != nil)
        }
    }

    @Test func defaultSessionPromptRendersRoleAppropriateTeamContext() throws {
        var repo = RepoEntry(path: "/r", displayName: "r")
        repo.worktrees.append(WorktreeEntry(path: "/r", branch: "main"))
        repo.worktrees.append(
            WorktreeEntry(path: "/r/feature-auth", branch: "feature/auth")
        )
        let team = try #require(TeamView.team(
            for: repo.worktrees[0],
            in: [repo],
            teamsEnabled: true
        ))
        let linkedViewer = try #require(
            team.members.first(where: { !$0.isMainWorktree })
        )
        let main = try #require(TeamInstructionsRenderer.render(
            template: DefaultPrompts.sessionPrompt,
            team: team,
            viewer: team.mainWorktree
        ))
        let linked = try #require(TeamInstructionsRenderer.render(
            template: DefaultPrompts.sessionPrompt,
            team: team,
            viewer: linkedViewer
        ))

        #expect(main.contains(#"You are "main" on branch `main` in repo "r"."#))
        #expect(main.contains("Worktree: `/r`."))
        #expect(main.contains("\"feature/auth\""))
        #expect(linked.contains("Worktree: `/r/feature-auth`."))
        #expect(linked.contains(#"Main worktree: "main" on `main` at `/r`."#))
    }

    /// The default per-event template uses a chained `{% if event.type == "…" %}`
    /// (Stencil has no `case`/`switch` tag) to give event-specific guidance.
    /// The merge_state_changed branch tells the agent to merge the default branch.
    @Test func defaultEventPromptBranchesOnEventType() throws {
        let event = ChannelServerMessage.event(
            type: "merge_state_changed",
            attrs: ["pr_number": "42", "from": "clean", "to": "dirty"],
            body: "PR #42 mergability: clean → dirty"
        )
        let result = EventBodyRenderer.split(
            event: event,
            recipientWorktreePath: "/r/alice",
            subjectWorktreePath: "/r/alice",
            repos: [
                RepoEntry(
                    path: "/r",
                    displayName: "r",
                    worktrees: [
                        WorktreeEntry(path: "/r",       branch: "main",  state: .running),
                        WorktreeEntry(path: "/r/alice", branch: "alice", state: .running),
                    ]
                )
            ],
            templateString: DefaultPrompts.eventPrompt
        )
        let prompt = try #require(result.agentPrompt)
        #expect(prompt.contains("merge the default branch"))
        // Sanity: the unrelated `pr_state_changed` branch must not have rendered.
        #expect(!prompt.contains("react to the new state"))
        #expect(!prompt.contains("automated team event"))
        #expect(!prompt.contains("your own worktree"))
        let expected = """
        PR #42 mergability: clean → dirty
        If the branch no longer merges cleanly, merge the default branch and resolve conflicts.
        """
        #expect(prompt == expected)
    }

    @Test func defaultEventPromptAddsGuidanceOnlyForActionableFailures() throws {
        let agent = EventBodyRenderer.makeAgentContext(
            branch: "alice",
            isMainWorktree: false,
            thisWorktree: true
        )
        func render(type: String, from: String, to: String, body: String) -> String? {
            EventBodyRenderer.renderAgentTemplate(
                DefaultPrompts.eventPrompt,
                agent: agent,
                body: body,
                event: [
                    "type": type,
                    "attrs": ["from": from, "to": to],
                    "body": body,
                ]
            )
        }

        #expect(render(
            type: "ci_conclusion_changed",
            from: "pending",
            to: "failure",
            body: "CI on PR #42: pending → failure"
        ) == "CI on PR #42: pending → failure\nInvestigate the failed checks and push a fix.")
        #expect(render(
            type: "ci_conclusion_changed",
            from: "failure",
            to: "pending",
            body: "CI on PR #42: failure → pending"
        ) == "CI on PR #42: failure → pending")
        #expect(render(
            type: "pr_state_changed",
            from: "open",
            to: "merged",
            body: "PR #42 state changed: open → merged"
        ) == "PR #42 state changed: open → merged")
    }

    @Test func teamSessionPromptAndTeamPromptAreIndependent() {
        let defaults = UserDefaults(suiteName: "AgentTeamsPaneTests-3")!
        defaults.removePersistentDomain(forName: "AgentTeamsPaneTests-3")
        defaults.set("session", forKey: "teamSessionPrompt")
        defaults.set("event",   forKey: "teamPrompt")
        #expect(defaults.string(forKey: "teamSessionPrompt") == "session")
        #expect(defaults.string(forKey: "teamPrompt") == "event")
    }

    @Test("""
    @spec TEAM-1.13: When the user activates "Restore Graftty Default" for either Agent Teams prompt editor, the application shall immediately replace the editor text with the corresponding built-in prompt and remove the persistent `UserDefaults` key so later built-in updates continue to apply.
    """)
    func restoreButtonsRepopulateEditorsAndRemoveOverrides() {
        let suite = "AgentTeamsPaneTests-Restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: DefaultPrompts.registrations)
        var sessionEditor = "custom session"
        var eventEditor = "custom event"
        defaults.set(sessionEditor, forKey: SettingsKeys.teamSessionPrompt)
        defaults.set(eventEditor, forKey: SettingsKeys.teamPrompt)

        #expect(sessionEditor == "custom session")
        #expect(eventEditor == "custom event")
        #expect(defaults.string(forKey: SettingsKeys.teamSessionPrompt) == "custom session")
        #expect(defaults.string(forKey: SettingsKeys.teamPrompt) == "custom event")

        DefaultPrompts.restoreSessionPrompt(in: defaults) {
            sessionEditor = $0
            defaults.set($0, forKey: SettingsKeys.teamSessionPrompt)
        }
        DefaultPrompts.restoreEventPrompt(in: defaults) {
            eventEditor = $0
            defaults.set($0, forKey: SettingsKeys.teamPrompt)
        }

        #expect(sessionEditor == DefaultPrompts.sessionPrompt)
        #expect(eventEditor == DefaultPrompts.eventPrompt)
        #expect(defaults.string(forKey: SettingsKeys.teamSessionPrompt) == DefaultPrompts.sessionPrompt)
        #expect(defaults.string(forKey: SettingsKeys.teamPrompt) == DefaultPrompts.eventPrompt)
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(persisted[SettingsKeys.teamSessionPrompt] == nil)
        #expect(persisted[SettingsKeys.teamPrompt] == nil)
    }
}
