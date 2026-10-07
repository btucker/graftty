import SwiftUI
import GrafttyProtocol

public struct SidebarWorktreeQuestion: View {
    public let context: SidebarWorktreeContext
    public init(context: SidebarWorktreeContext) { self.context = context }

    public var body: some View {
        if let question = context.question {
            VStack(alignment: .leading, spacing: 3) {
                Text("Needs your input").font(.caption2).fontWeight(.semibold).foregroundStyle(.orange)
                Text(question).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 9)
            .overlay(alignment: .leading) { Rectangle().fill(.orange.opacity(0.7)).frame(width: 2) }
            .padding(.vertical, 5)
            .accessibilityElement(children: .combine)
        }
    }
}

public struct SidebarWorktreeReport: View {
    public let context: SidebarWorktreeContext
    public let onOpen: () async -> Bool
    public let onDismiss: () -> Void
    public let onClose: () -> Void
    @State private var opening = false
    @State private var error = false

    public init(context: SidebarWorktreeContext, onOpen: @escaping () async -> Bool,
                onDismiss: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.context = context; self.onOpen = onOpen; self.onDismiss = onDismiss; self.onClose = onClose
    }

    public var body: some View {
        let card = SidebarAttentionCardContent(item: context.item)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.headerName).font(.subheadline).fontWeight(.semibold)
                    if let branch = card.branchName { Text(branch).font(.caption2).foregroundStyle(.secondary) }
                    if let pane = card.paneTitle { Text(pane).font(.caption2).foregroundStyle(.secondary) }
                    if let badge = context.item.prBadge { SidebarPRBadge(badge: badge) }
                    if context.isRunning { Label("Running", systemImage: "circle.fill").font(.caption2).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close report")
            }
            if let stop = context.item.agentStop {
                Text("\(context.isRunning ? "Previous report" : "Last report") · \(stop.elapsedDescription(at: .now))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(context.item.agentStop?.recap == nil ? "No report yet" : card.title).font(.headline)
                    if card.sections.isEmpty {
                        Text(context.pending.first?.title ?? "This worktree has no saved agent recap.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(card.sections) { section in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(label(section.kind)).font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(section.kind == .needsYou && context.question != nil ? Color.orange : .secondary)
                            Text(section.text).font(.callout)
                            if let detail = section.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if error { Text("Couldn't open this worktree. Its request may have changed.").font(.caption).foregroundStyle(.red) }
            Divider()
            HStack {
                if !context.pending.isEmpty {
                    Button("Dismiss request") { onDismiss(); onClose() }.font(.caption)
                }
                Spacer()
                Button(opening ? "Opening…" : "Open worktree") {
                    opening = true
                    Task { @MainActor in
                        let succeeded = await onOpen()
                        opening = false
                        error = !succeeded
                        if succeeded { onClose() }
                    }
                }.disabled(opening || !context.worktree.state.hasOnDiskWorktree)
            }
        }.padding(16)
    }

    private func label(_ kind: SidebarAttentionCardContent.Section.Kind) -> String {
        switch kind {
        case .context: "Context"
        case .needsYou: context.question == nil ? "Question from report" : "Needs your input"
        case .upNext: "Next"
        }
    }
}
