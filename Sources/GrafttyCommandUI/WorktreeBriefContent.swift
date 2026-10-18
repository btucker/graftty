import GrafttyProtocol
import SwiftUI

/// The same current brief and expandable evolution on both platforms.
public struct WorktreeBriefContent: View {
    public let context: SidebarWorktreeContext
    private let foreground: Color
    private let secondary: Color
    private let compact: Bool
    @State private var showsHistory = false

    public init(context: SidebarWorktreeContext, foreground: Color = .primary, secondary: Color = .secondary, compact: Bool = false) {
        self.context = context
        self.foreground = foreground
        self.secondary = secondary
        self.compact = compact
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
                if !brief.history.isEmpty {
                    Divider()
                    DisclosureGroup(isExpanded: $showsHistory) {
                        VStack(alignment: .leading, spacing: 22) {
                            ForEach(brief.history.reversed()) { checkpoint in
                                HStack(alignment: .top, spacing: 12) {
                                    Circle().fill(secondary).frame(width: 6, height: 6).padding(.top, 7)
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(Date(timeIntervalSinceReferenceDate: checkpoint.timestamp), style: .date)
                                            .font(.caption2).foregroundStyle(secondary)
                                        Text(checkpoint.title).font(.callout).fontWeight(.semibold)
                                        Text(checkpoint.completed).font(.callout)
                                            .fixedSize(horizontal: false, vertical: true)
                                        ForEach(Array(checkpoint.decisions.enumerated()), id: \.offset) { _, decision in
                                            Text(decision).font(.caption).foregroundStyle(secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }.padding(.top, 16)
                    } label: {
                        Text("How we got here").font(.callout).padding(.vertical, 10)
                    }
                    .accessibilityIdentifier("worktree.context.history")
                }
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
                Text("Agent reports will build a current brief and decision history here.")
                    .font(.callout).foregroundStyle(secondary)
                if let question = context.question { section("Waiting for you", text: question) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(foreground)
        .textSelection(.enabled)
        .onChange(of: context.item.worktreeIdentity) { _, _ in showsHistory = false }
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
