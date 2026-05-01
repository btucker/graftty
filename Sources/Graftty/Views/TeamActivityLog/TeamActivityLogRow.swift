import SwiftUI
import GrafttyKit

/// A single row in the Team Activity Log window. Renders as either a
/// chat bubble (`team_message` from a non-system sender, TEAM-7.5) or a
/// system entry — kind-specific SF Symbol + headline + body — for
/// every other inbox `kind` (system events, team_member_joined/left,
/// PR/CI/merge transitions, plus unknown future kinds via the
/// generic-fallback branch, TEAM-7.7).
struct TeamActivityLogRow: View {
    let message: TeamInboxMessage

    /// Exposed as a unit-testable computed property so the rendering
    /// decision (chat-bubble vs system-entry, plus the SF Symbol /
    /// headline lookup) can be asserted without hosting SwiftUI views.
    enum Style: Equatable {
        case chatBubble(senderName: String, recipientName: String, priority: TeamInboxPriority)
        case systemEntry(symbolName: String, headline: String)
    }

    var style: Style {
        if message.from.member == "system" || message.kind != "team_message" {
            return Self.systemStyle(forKind: message.kind)
        }
        return .chatBubble(
            senderName: message.from.member,
            recipientName: message.to.member,
            priority: message.priority
        )
    }

    private static func systemStyle(forKind kind: String) -> Style {
        switch kind {
        case "pr_state_changed":
            return .systemEntry(symbolName: "circle.fill", headline: "PR state changed")
        case "ci_conclusion_changed":
            return .systemEntry(symbolName: "checkmark.seal", headline: "CI conclusion changed")
        case "merge_state_changed":
            return .systemEntry(symbolName: "arrow.triangle.merge", headline: "Mergability changed")
        case "team_member_joined":
            return .systemEntry(symbolName: "person.fill.badge.plus", headline: "Team member joined")
        case "team_member_left":
            return .systemEntry(symbolName: "person.fill.badge.minus", headline: "Team member left")
        default:
            return .systemEntry(symbolName: "info.circle", headline: kind)
        }
    }

    var body: some View {
        switch style {
        case let .chatBubble(senderName, recipientName, priority):
            ChatBubbleView(
                senderName: senderName,
                recipientName: recipientName,
                text: message.body,
                createdAt: message.createdAt,
                priority: priority
            )
        case let .systemEntry(symbolName, headline):
            SystemEntryView(
                symbolName: symbolName,
                headline: headline,
                text: message.body,
                createdAt: message.createdAt
            )
        }
    }
}

private struct ChatBubbleView: View {
    let senderName: String
    let recipientName: String
    let text: String
    let createdAt: Date
    let priority: TeamInboxPriority

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(senderName) → \(recipientName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if priority == .urgent {
                    Text("URGENT")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.red)
                }
                Spacer()
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Text(text)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SystemEntryView: View {
    let symbolName: String
    let headline: String
    let text: String
    let createdAt: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbolName).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline).font(.caption).bold()
                Text(text).font(.caption).foregroundStyle(.secondary)
                Text(createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}
