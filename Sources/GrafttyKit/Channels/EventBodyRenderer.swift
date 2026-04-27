import Foundation
import os
import Stencil

/// Renders the user's `teamPrompt` Stencil template against the per-delivery
/// `agent` context and returns a `ChannelServerMessage` with the rendered text
/// prepended to the body. On empty template, empty render, or render failure,
/// returns the original event unchanged. Implements TEAM-3.3.
public enum EventBodyRenderer {

    private static let logger = Logger(subsystem: "com.btucker.graftty", category: "EventBodyRenderer")

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

        let agentDict: [String: Any] = [
            "branch": recipient?.branch ?? "",
            "lead": isLead,
            "this_worktree": isThisWorktree,
            "other_worktree": isOtherWorktree,
        ]
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
            rendered = try Environment().renderTemplate(string: template, context: context)
        } catch {
            logger.error("agent template render failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let trimmed = rendered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Convenience: returns a `@MainActor (path, message) -> Void` closure that renders
    /// the user's `teamPrompt` template against each delivery before passing
    /// the rendered message to `inner`. Use at every dispatch call site so the
    /// matrix-routed events and team-internal events share rendering behavior.
    public static func dispatchClosure(
        repos: [RepoEntry],
        inner: @escaping @MainActor (String, ChannelServerMessage) -> Void
    ) -> @MainActor (String, ChannelServerMessage) -> Void {
        return { path, msg in
            let template = UserDefaults.standard.string(forKey: "teamPrompt") ?? ""
            let subjectPath: String? = {
                if case let .event(_, attrs, _) = msg { return attrs["worktree"] }
                return nil
            }()
            let rendered = EventBodyRenderer.body(
                for: msg,
                recipientWorktreePath: path,
                subjectWorktreePath: subjectPath,
                repos: repos,
                templateString: template
            )
            inner(path, rendered)
        }
    }
}
