import Foundation
import os
import Stencil

/// Team-inbox renderer. Renders the user's `teamPrompt` Stencil template
/// against the per-delivery `agent` context and returns a
/// `ChannelServerMessage` with the rendered text prepended to the body.
/// On empty template, empty render, or render failure, returns the
/// original event unchanged. Implements TEAM-3.3.
public enum EventBodyRenderer {

    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "EventBodyRenderer")

    /// Shared Stencil environment. Hot-path: rendered per-event-per-recipient
    /// and again per-session-start, so reuse the cached filter/extension
    /// registry instead of allocating a fresh `Environment` per call.
    private static let sharedEnvironment = Environment()

    /// Builds the `[String: Any]` agent dict consumed by every Stencil render
    /// in `Graftty`. Centralizes the four key strings so the wire shape can't
    /// drift between call sites (`body(...)`, team-instructions composition,
    /// tests). Worktree-scoped flags default to `false` for the session-start
    /// path where no event exists yet.
    public static func makeAgentContext(
        branch: String,
        lead: Bool,
        thisWorktree: Bool = false,
        otherWorktree: Bool = false
    ) -> [String: Any] {
        [
            "branch": branch,
            "lead": lead,
            "this_worktree": thisWorktree,
            "other_worktree": otherWorktree,
        ]
    }

    public static func body(
        for event: ChannelServerMessage,
        recipientWorktreePath: String,
        subjectWorktreePath: String?,
        repos: [RepoEntry],
        templateString: String
    ) -> ChannelServerMessage {
        // Empty template = passthrough.
        guard !templateString.isEmpty else { return event }
        guard case let .event(type, attrs, originalBody) = event else { return event }

        // Compute the agent context for this delivery.
        let recipientRepo = repos.first { repo in
            repo.worktrees.contains(where: { $0.path == recipientWorktreePath })
        }
        let recipient = recipientRepo?.worktrees.first(where: { $0.path == recipientWorktreePath })

        let isLead = (recipientRepo?.path == recipientWorktreePath)
        let isThisWorktree: Bool = {
            guard let subject = subjectWorktreePath else { return false }
            return subject == recipientWorktreePath
        }()
        let isOtherWorktree: Bool = {
            guard let subject = subjectWorktreePath else { return false }
            return subject != recipientWorktreePath
        }()

        let agentDict = makeAgentContext(
            branch: recipient?.branch ?? "",
            lead: isLead,
            thisWorktree: isThisWorktree,
            otherWorktree: isOtherWorktree
        )
        guard let rendered = renderAgentTemplate(templateString, agent: agentDict) else {
            return event
        }

        return .event(type: type, attrs: attrs, body: "\(rendered)\n\n\(originalBody)")
    }
}

extension EventBodyRenderer {
    /// Renders a Stencil template against an agent-context dict. Returns the
    /// trimmed rendered string, or nil on render failure / empty result.
    /// Centralizes the render + trim + error-log logic shared by per-event
    /// rendering and session-start MCP-instructions rendering.
    public static func renderAgentTemplate(
        _ template: String,
        agent: [String: Any]
    ) -> String? {
        guard !template.isEmpty else { return nil }
        let context: [String: Any] = ["agent": agent]
        let rendered: String
        do {
            rendered = try sharedEnvironment.renderTemplate(string: template, context: context)
        } catch {
            logger.error("agent template render failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Convenience: renders the user's `teamSessionPrompt` against a session-
    /// start agent context (only `branch` and `lead` are meaningful before any
    /// event has fired).
    public static func renderSessionPrompt(
        template: String,
        branch: String,
        lead: Bool
    ) -> String? {
        renderAgentTemplate(template, agent: makeAgentContext(branch: branch, lead: lead))
    }

}
