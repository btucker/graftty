import Foundation
import os
import Stencil

/// Result of rendering a team-inbox event template. Carries the original
/// event (the body field is unchanged from what arrived on the wire) plus
/// the rendered `agentPrompt` — the per-recipient text the dispatcher
/// will deliver to the agent. `agentPrompt` is nil iff the template was
/// empty, the render failed, or the rendered output was empty after
/// trimming.
public struct EventBodyRendererResult: Equatable {
    public let event: ChannelServerMessage
    public let agentPrompt: String?

    public init(event: ChannelServerMessage, agentPrompt: String?) {
        self.event = event
        self.agentPrompt = agentPrompt
    }
}

/// Team-inbox renderer. Renders the user's `teamPrompt` Stencil template
/// against the per-delivery `agent` context and returns the original
/// event plus the rendered agent prompt as separate fields. Stencil
/// templates may reference `{{ body }}` to control where the event
/// content appears; templates that don't reference it get
/// `\n\n{{ body }}` auto-appended before rendering, preserving the
/// pre-split prepend behavior. On empty template, empty render, or
/// render failure, returns the original event with `agentPrompt = nil`.
/// Implements TEAM-3.3.
public enum EventBodyRenderer {

    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "EventBodyRenderer")

    /// Shared Stencil environment. Hot-path: rendered per-event-per-recipient
    /// and again per-session-start, so reuse the cached filter/extension
    /// registry instead of allocating a fresh `Environment` per call.
    private static let sharedEnvironment = Environment()

    /// Regex matches a Stencil `body` reference with any internal whitespace
    /// — `{{ body }}`, `{{body}}`, `{{  body  }}`. Used to decide whether the
    /// renderer should auto-append `\n\n{{ body }}` to a template that
    /// hasn't placed the body itself.
    private static let bodyReferencePattern = try! NSRegularExpression(
        pattern: #"\{\{\s*body\s*\}\}"#
    )

    private static func referencesBody(_ template: String) -> Bool {
        let range = NSRange(template.startIndex..., in: template)
        return bodyReferencePattern.firstMatch(in: template, range: range) != nil
    }

    /// Builds the `[String: Any]` agent dict consumed by every Stencil render
    /// in `Graftty`. Centralizes the four key strings so the wire shape can't
    /// drift between call sites (`split(...)`, team-instructions composition,
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

    public static func split(
        event: ChannelServerMessage,
        recipientWorktreePath: String,
        subjectWorktreePath: String?,
        repos: [RepoEntry],
        templateString: String
    ) -> EventBodyRendererResult {
        // Empty template = passthrough.
        guard !templateString.isEmpty else {
            return EventBodyRendererResult(event: event, agentPrompt: nil)
        }
        guard case let .event(_, _, originalBody) = event else {
            return EventBodyRendererResult(event: event, agentPrompt: nil)
        }

        // Compute the agent context for this delivery (unchanged from the
        // pre-split body(...) function).
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

        // Auto-append `\n\n{{ body }}` to templates that don't reference
        // the body themselves, so out-of-the-box templates and legacy
        // user-customized templates keep producing today's "prelude
        // followed by body" output without migration.
        let effectiveTemplate = referencesBody(templateString)
            ? templateString
            : "\(templateString)\n\n{{ body }}"

        guard let rendered = renderAgentTemplate(
            effectiveTemplate,
            agent: agentDict,
            body: originalBody
        ) else {
            return EventBodyRendererResult(event: event, agentPrompt: nil)
        }

        return EventBodyRendererResult(event: event, agentPrompt: rendered)
    }
}

extension EventBodyRenderer {
    /// Renders a Stencil template against an agent-context dict, with an
    /// optional top-level `body` variable carrying the original event
    /// content. Returns the trimmed rendered string, or nil on render
    /// failure / empty result. `body` defaults to nil for the session-
    /// start path where no event is in flight.
    public static func renderAgentTemplate(
        _ template: String,
        agent: [String: Any],
        body: String? = nil
    ) -> String? {
        guard !template.isEmpty else { return nil }
        var context: [String: Any] = ["agent": agent]
        if let body { context["body"] = body }
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
