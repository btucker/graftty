import GrafttyProtocol
import SwiftUI

/// The Context scroll's sections, top to bottom.
public enum WorktreeContextSection: Equatable, Sendable {
    /// Path, purpose, decisions and completed agents, behind the title (CONTEXT-59).
    case details
    case timeline
    /// The present state: completed, then Next (CONTEXT-58).
    case now
    /// No brief yet.
    case empty
    /// A question waiting for the user (CONTEXT-61).
    case ask
    case status
}

extension WorktreeContextPanel {
    /// The brief's title, else the worktree's name; never a static label (CONTEXT-27).
    public static func headerTitle(for context: SidebarWorktreeContext) -> String {
        context.brief?.title ?? context.worktree.displayName
    }

    /// Pass the timeline the caller already built; building one sorts all history.
    public static func sections(for context: SidebarWorktreeContext, showsDetails: Bool,
                                timeline: WorktreeTimeline? = nil) -> [WorktreeContextSection] {
        var sections: [WorktreeContextSection] = showsDetails ? [.details] : []
        if !(timeline ?? WorktreeTimeline(context)).events.isEmpty { sections.append(.timeline) }
        sections.append(context.brief == nil ? .empty : .now)
        if context.question != nil { sections.append(.ask) }
        if context.brief != nil || context.isRunning { sections.append(.status) }
        return sections
    }
}

/// Where things stand: the loudest text on the panel, with the next step under it.
struct WorktreeContextNow: View {
    let brief: WorktreeBrief
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(brief.completed).font(.body).fontWeight(.medium).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Next").font(.caption).fontWeight(.semibold)
                Text(brief.next).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("worktree.context.now")
    }
}

/// What a brief without a report shows, and the quiet line under everything.
struct WorktreeContextEmpty: View {
    let context: SidebarWorktreeContext
    let secondary: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No context yet").font(.headline)
            Text(context.pending.first?.title ?? "Agent reports will build a current brief and decision history here.")
                .font(.callout).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WorktreeContextStatus: View {
    let context: SidebarWorktreeContext
    let secondary: Color

    var body: some View {
        HStack(spacing: 4) {
            if context.isRunning { Text(context.brief == nil ? "Agent working" : "Agent working ·") }
            if let brief = context.brief {
                Text("Updated")
                Text(Date(timeIntervalSinceReferenceDate: brief.updatedAt), style: .relative)
                Text("ago")
            }
        }
        .font(.caption).italic().foregroundStyle(secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The worktree path, purpose and decisions, shown when the title is activated.
struct WorktreeContextDetails<Agents: View>: View {
    let context: SidebarWorktreeContext
    let secondary: Color
    @ViewBuilder let completedAgents: Agents

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(context.worktree.repoDisplayName) / \(context.worktree.displayName)")
                .font(.caption).foregroundStyle(secondary)
            if let purpose = context.brief?.context {
                Text(purpose).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let decisions = context.brief?.decisions, !decisions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Settled").font(.caption).fontWeight(.medium).foregroundStyle(secondary)
                    ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(secondary)
                            Text(decision).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }
            completedAgents
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("worktree.context.details")
    }
}
