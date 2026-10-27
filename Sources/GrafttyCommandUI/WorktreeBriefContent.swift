import GrafttyProtocol
import SwiftUI

/// The same current brief and chronological history on both platforms.
/// The Context panel omits the history here and places `WorktreeContextHistory` itself.
public struct WorktreeBriefContent: View {
    public let context: SidebarWorktreeContext
    private let foreground: Color
    private let secondary: Color
    private let compact: Bool
    private let includesHistory: Bool

    public init(context: SidebarWorktreeContext, foreground: Color = .primary, secondary: Color = .secondary,
                compact: Bool = false, includesHistory: Bool = true) {
        self.context = context
        self.foreground = foreground
        self.secondary = secondary
        self.compact = compact
        self.includesHistory = includesHistory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 24) {
            VStack(alignment: .leading, spacing: 8) {
                if !compact {
                    Text("\(context.worktree.repoDisplayName) / \(context.worktree.displayName)")
                        .font(.caption).foregroundStyle(secondary)
                }
                Text(context.brief?.title ?? context.worktree.displayName)
                    .font(compact ? .headline : .title2).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                if let purpose = context.brief?.context {
                    Text(purpose).font(compact ? .callout : .body).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let brief = context.brief {
                section("Where we are", text: brief.completed)
                if !brief.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        sectionLabel("What we’ve settled")
                        ForEach(Array(brief.decisions.enumerated()), id: \.offset) { _, decision in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(secondary)
                                Text(decision).fixedSize(horizontal: false, vertical: true)
                            }.font(.callout)
                        }
                    }
                }
                if let question = context.question {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Waiting for you").font(.caption).foregroundStyle(.orange)
                        Text(question).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 2) }
                }
                section("Up next", text: brief.next)
                if !compact {
                    HStack(spacing: 4) {
                        if context.isRunning { Text("Agent running ·") }
                        Text("Updated")
                        Text(Date(timeIntervalSinceReferenceDate: brief.updatedAt), style: .relative)
                    }
                    .font(.caption2).foregroundStyle(secondary)
                    .accessibilityElement(children: .combine)
                }
            } else {
                Text("No context yet").font(.headline)
                Text(context.pending.first?.title ?? "Agent reports will build a current brief and decision history here.")
                    .font(.callout).foregroundStyle(secondary)
                if let question = context.question { section("Waiting for you", text: question) }
            }
            if includesHistory {
                let timeline = WorktreeTimeline(context)
                if !timeline.events.isEmpty {
                    Divider()
                    WorktreeContextHistory(context: context, timeline: timeline, secondary: secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(foreground)
        .textSelection(.enabled)
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label).font(.caption).fontWeight(.medium).foregroundStyle(secondary)
    }

    private func section(_ label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            sectionLabel(label)
            Text(text).font(.callout).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension WorktreeTimeline {
    public init(_ context: SidebarWorktreeContext) {
        self.init(history: context.worktree.sidebar?.history, brief: context.brief)
    }
}

/// The worktree's chronological history, wired to the environment's navigation actions.
struct WorktreeContextHistory: View {
    let context: SidebarWorktreeContext
    let timeline: WorktreeTimeline
    let secondary: Color
    @Environment(\.worktreeContextActions) private var actions

    var body: some View {
        WorktreeHistoryContent(timeline: timeline, secondary: secondary,
            openWorktree: actions.map { actions in { actions.openWorktree($0, context.worktree) } },
            revealInTerminal: revealInTerminal)
            .id(context.item.worktreeIdentity)
    }

    private var revealInTerminal: (@MainActor (String) async -> Bool)? {
        guard let reveal = actions?.revealInTerminal, let paneID = context.agentPaneID else { return nil }
        let worktree = context.worktree, messages = ScrollbackMap.messages(in: timeline)
        return { eventID in
            await reveal(TerminalRevealRequest(worktree: worktree, paneID: paneID, eventID: eventID, messages: messages))
        }
    }
}
