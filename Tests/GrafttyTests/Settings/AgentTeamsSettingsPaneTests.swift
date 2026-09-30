import Testing
import SwiftUI
import GrafttyKit
@testable import Graftty

@Suite("AgentTeamsSettingsPane Tests")
struct AgentTeamsSettingsPaneTests {

    @Test("""
    @spec TEAM-1.6: The Agent Teams Settings pane shall expose one user-editable Stencil-templated text area, `teamPrompt`, backed by `@AppStorage` and registered into `UserDefaults.standard` at app startup so non-binding readers see the same default until the user overrides it. Clearing the field to the empty string disables that prompt. It shall retain a non-empty compact automated-event default that renders the event body first, adds only event-specific actionable guidance, and omits generic delivery and same-worktree preambles; it shall render per recipient against the four event-scoped `agent` fields plus top-level `body` and `event` (`event.type`, `event.attrs`, `event.body`). Authored `team_message` rows bypass this event template and store no `agent_prompt`; automated events store rendered `agent_prompt` separately from their unchanged `body`. If an event template omits `{{ body }}`, the renderer appends it before rendering so older templates continue to surface event content. Hook delivery emits authored messages from raw `body`, automated events from `agent_prompt` when present, and otherwise falls through to `body`. Agents are customized per repository and worktree through `GRAFTTY.md` instruction files rather than a session prompt setting.
    """)
    func eventPromptIsTheOnlyEditablePrompt() {
        #expect(!DefaultPrompts.eventPrompt.isEmpty)
        #expect(DefaultPrompts.registrations.keys.sorted() == [SettingsKeys.teamPrompt])
    }

    @Test func eventPromptIsCompactAndUsesEventContext() {
        let p = DefaultPrompts.eventPrompt
        #expect(p.contains("{{ body }}"))
        #expect(p.contains("event.type"))
        #expect(!p.contains("automated team event"))
        #expect(!p.lowercased().contains("this event is about"))
    }

    /// Catches Stencil syntax errors in the per-event prompt across event
    /// agent shapes.
    @Test func defaultPromptsRenderUnderEveryAgentContext() {
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

    @Test("""
    @spec TEAM-1.13: When the user activates Restore Graftty Default for the per-event prompt editor, the application shall immediately replace the editor text with the built-in prompt and remove the persistent `UserDefaults` key so later built-in updates continue to apply.
    """)
    func restoreButtonRepopulatesEditorAndRemovesOverride() {
        let suite = "AgentTeamsPaneTests-Restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.register(defaults: DefaultPrompts.registrations)
        var eventEditor = "custom event"
        defaults.set(eventEditor, forKey: SettingsKeys.teamPrompt)
        #expect(defaults.string(forKey: SettingsKeys.teamPrompt) == "custom event")

        DefaultPrompts.restoreEventPrompt(in: defaults) {
            eventEditor = $0
            defaults.set($0, forKey: SettingsKeys.teamPrompt)
        }

        #expect(eventEditor == DefaultPrompts.eventPrompt)
        #expect(defaults.string(forKey: SettingsKeys.teamPrompt) == DefaultPrompts.eventPrompt)
        let persisted = defaults.persistentDomain(forName: suite) ?? [:]
        #expect(persisted[SettingsKeys.teamPrompt] == nil)
    }

    @Test("""
    @spec AGENT-6.46: While the current Codex and Claude provider plugin integration is not installed, the Agent Teams Settings pane shall warn that agents will not be connected to Graftty until the plugins are installed and offer the install action; once the current integration is installed, the warning shall disappear.
    """)
    func warnsUntilProviderPluginsAreInstalled() throws {
        let suite = "AgentTeamsPaneTests-PluginWarning-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let warning = try #require(AgentTeamsSettingsPane.missingPluginsWarning(in: defaults))
        #expect(warning.contains("won't be connected to Graftty"))
        #expect(warning.contains("Install"))

        defaults.set(
            AgentPluginInstaller.integrationRevision - 1,
            forKey: SettingsKeys.agentPluginInstalledRevision
        )
        #expect(AgentTeamsSettingsPane.missingPluginsWarning(in: defaults) != nil)

        AgentPluginInstallOfferPolicy.recordInstalled(in: defaults, buildVersion: nil)
        #expect(AgentTeamsSettingsPane.missingPluginsWarning(in: defaults) == nil)
    }
}
