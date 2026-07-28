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

/// Automated-event renderer. Renders the user's `teamPrompt` Stencil template
/// against the per-delivery `agent` context and returns the original event
/// plus the rendered agent prompt as separate fields. Authored `team_message`
/// rows bypass this renderer. Stencil templates may reference `{{ body }}`
/// to control where the event content appears; templates that don't reference it get
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

    /// Builds the event-delivery `agent` dictionary. The full session-start
    /// context is a superset built by `TeamInstructionsRenderer`; it preserves
    /// these four shared keys while adding session identity and team data.
    public static func makeAgentContext(
        branch: String,
        isMainWorktree: Bool,
        thisWorktree: Bool = false,
        otherWorktree: Bool = false
    ) -> [String: Any] {
        [
            "branch": branch,
            "main_worktree": isMainWorktree,
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
        guard case let .event(eventType, eventAttrs, originalBody) = event else {
            return EventBodyRendererResult(event: event, agentPrompt: nil)
        }

        // Compute the agent context for this delivery.
        let recipientRepo = repos.first { repo in
            repo.worktrees.contains(where: { $0.path == recipientWorktreePath })
        }
        let recipient = recipientRepo?.worktrees.first(where: { $0.path == recipientWorktreePath })

        let isMainWorktree = (recipientRepo?.path == recipientWorktreePath)
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
            isMainWorktree: isMainWorktree,
            thisWorktree: isThisWorktree,
            otherWorktree: isOtherWorktree
        )

        // Auto-append `\n\n{{ body }}` to templates that don't reference
        // the body themselves, so out-of-the-box templates and legacy
        // user-customized templates keep producing today's "prelude
        // followed by body" output without migration. Trim trailing
        // whitespace before splicing so a template that ends in `\n`
        // doesn't produce three blank lines between prelude and body.
        let effectiveTemplate: String = {
            if referencesBody(templateString) { return templateString }
            let trimmedTrailing = templateString.replacingOccurrences(
                of: #"\s+$"#,
                with: "",
                options: .regularExpression
            )
            return "\(trimmedTrailing)\n\n{{ body }}"
        }()

        let eventDict: [String: Any] = [
            "type": eventType,
            "attrs": eventAttrs,
            "body": originalBody,
        ]

        guard let rendered = renderAgentTemplate(
            effectiveTemplate,
            agent: agentDict,
            body: originalBody,
            event: eventDict
        ) else {
            return EventBodyRendererResult(event: event, agentPrompt: nil)
        }

        return EventBodyRendererResult(event: event, agentPrompt: rendered)
    }
}

extension EventBodyRenderer {
    /// Renders a Stencil template against an agent-context dict, with
    /// optional top-level `body`, `event`, and caller-provided context.
    /// Returns the trimmed rendered string, or nil on render failure / empty
    /// result. `body` and `event` default to nil for the session-start path.
    public static func renderAgentTemplate(
        _ template: String,
        agent: [String: Any],
        body: String? = nil,
        event: [String: Any]? = nil,
        additionalContext: [String: Any] = [:]
    ) -> String? {
        guard !template.isEmpty else { return nil }
        var context = additionalContext
        context["agent"] = agent
        if let body { context["body"] = body }
        if let event { context["event"] = event }
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

}
