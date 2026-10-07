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
            .frame(maxWidth: .infinity, alignment: .leading)
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
        VStack(alignment: .leading, spacing: 14) {
            SidebarWorktreeReportContent(context: context, scrolls: true, onClose: onClose)
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
}

/// Report text shared by the Mac popover and the mobile report sheet.
/// @spec LAYOUT-2.135: While a worktree report is previewed, the application shall group compact identity metadata on a contrasting background, label completed work, and inset its question with an accent for pending input and a neutral treatment for viewed questions.
public struct SidebarWorktreeReportContent: View {
    public let context: SidebarWorktreeContext
    private let foreground: Color
    private let secondary: Color
    private let scrolls: Bool
    private let onClose: (() -> Void)?

    public init(context: SidebarWorktreeContext, foreground: Color = .primary,
                secondary: Color = .secondary, scrolls: Bool = false, onClose: (() -> Void)? = nil) {
        self.context = context
        self.foreground = foreground
        self.secondary = secondary
        self.scrolls = scrolls
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            reportIdentity
            if scrolls {
                ScrollView { sections }
            } else {
                sections
            }
        }.foregroundStyle(foreground)
    }

    private var reportIdentity: some View {
        let card = SidebarAttentionCardContent(item: context.item)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(card.headerName).font(.caption).fontWeight(.semibold)
                    .lineLimit(1).help(card.headerName)
                Spacer(minLength: 0)
                if let badge = context.item.prBadge { SidebarPRBadge(badge: badge).fixedSize() }
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Close report")
                }
            }
            if let branch = card.branchName {
                Text(branch).font(.caption2).fontWeight(.regular).foregroundStyle(secondary)
                    .lineLimit(1).help(branch)
            }
            if let pane = card.paneTitle {
                Text(pane).font(.caption2).fontWeight(.regular).foregroundStyle(secondary)
                    .lineLimit(1).help(pane)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { runningStatus.fixedSize(); Spacer(minLength: 0); reportAge.fixedSize() }
                VStack(alignment: .leading, spacing: 4) { runningStatus; reportAge }
            }
            .font(.caption2).fontWeight(.regular).foregroundStyle(secondary)
            .padding(.top, 2)
        }
        .padding(10)
        .background(foreground.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder private var runningStatus: some View {
        if context.isRunning {
            Label("Running", systemImage: "circle.fill")
        }
    }

    @ViewBuilder private var reportAge: some View {
        if let stop = context.item.agentStop {
            Text("\(context.isRunning ? "Previous report" : "Last report") · \(stop.elapsedDescription(at: .now))")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sections: some View {
        let card = SidebarAttentionCardContent(item: context.item)
        return VStack(alignment: .leading, spacing: 22) {
            Text(context.item.agentStop?.recap == nil ? "No report yet" : card.title)
                .font(.headline).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if card.sections.isEmpty {
                Text(context.pending.first?.title ?? "This worktree has no saved agent recap.")
                    .font(.callout).fontWeight(.regular).foregroundStyle(secondary)
            }
            ForEach(card.sections) { section in
                if section.kind == .needsYou {
                    questionSection(section)
                } else {
                    narrativeSection(section)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func narrativeSection(_ section: SidebarAttentionCardContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label(section.kind)).font(.caption).fontWeight(.semibold).foregroundStyle(secondary)
            Text(section.text).font(.callout).fontWeight(.regular).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = section.detail {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Completed").font(.caption).fontWeight(.semibold)
                    Text(detail).font(.caption).fontWeight(.regular).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(secondary).padding(.top, 5)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func questionSection(_ section: SidebarAttentionCardContent.Section) -> some View {
        let accent = context.question == nil ? foreground : Color.orange
        return VStack(alignment: .leading, spacing: 8) {
            Label(label(section.kind), systemImage: "bubble.left")
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(foreground)
            Text(section.text).font(.callout).fontWeight(.medium).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(accent.opacity(context.question == nil ? 0.05 : 0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(accent.opacity(context.question == nil ? 0.16 : 0.4), lineWidth: 1)
            .allowsHitTesting(false))
        .accessibilityElement(children: .combine)
    }

    private func label(_ kind: SidebarAttentionCardContent.Section.Kind) -> String {
        switch kind {
        case .context: "Context"
        case .needsYou: context.question == nil ? "Question from report" : "Needs your input"
        case .upNext: "Next"
        }
    }
}
