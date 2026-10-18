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
    public let onOpenPort: ((WorktreePort) -> Void)?
    @State private var opening = false
    @State private var error = false

    public init(context: SidebarWorktreeContext, onOpen: @escaping () async -> Bool,
                onDismiss: @escaping () -> Void, onClose: @escaping () -> Void,
                onOpenPort: ((WorktreePort) -> Void)? = nil) {
        self.context = context; self.onOpen = onOpen; self.onDismiss = onDismiss; self.onClose = onClose
        self.onOpenPort = onOpenPort
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarWorktreeReportContent(context: context, scrolls: true, onClose: onClose, onOpenPort: onOpenPort)
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
/// @spec LAYOUT-2.135: While a worktree report is previewed, the application shall group compact identity metadata on a contrasting background and display the retained current brief, live waiting question, and expandable checkpoint history.
public struct SidebarWorktreeReportContent: View {
    public let context: SidebarWorktreeContext
    private let foreground: Color
    private let secondary: Color
    private let scrolls: Bool
    private let onClose: (() -> Void)?
    private let onOpenPort: ((WorktreePort) -> Void)?

    public init(context: SidebarWorktreeContext, foreground: Color = .primary,
                secondary: Color = .secondary, scrolls: Bool = false, onClose: (() -> Void)? = nil,
                onOpenPort: ((WorktreePort) -> Void)? = nil) {
        self.context = context
        self.foreground = foreground
        self.secondary = secondary
        self.scrolls = scrolls
        self.onClose = onClose
        self.onOpenPort = onOpenPort
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
        VStack(alignment: .leading, spacing: 22) {
            if !context.worktree.ports.isEmpty {
                SidebarWorktreePorts(ports: context.worktree.ports, onOpen: onOpenPort)
            }
            WorktreeBriefContent(context: context, foreground: foreground, secondary: secondary, compact: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

}

/// Port controls belong to the report, independently of terminal selection.
public struct SidebarWorktreePorts: View {
    public let ports: [WorktreePort]
    public let onOpen: ((WorktreePort) -> Void)?

    public init(ports: [WorktreePort], onOpen: ((WorktreePort) -> Void)? = nil) {
        self.ports = ports
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Listening ports").font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(ports) { port in
                Button { onOpen?(port) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: port.scope == .loopback ? "personalhotspot" : "globe")
                            .fixedSize().frame(width: 24)
                        Text(":\(String(port.port))").monospacedDigit().fontWeight(.medium).fixedSize()
                        Text(port.processName).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").foregroundStyle(.secondary).fixedSize().frame(width: 24)
                    }
                    .font(.callout).padding(.vertical, 8).padding(.horizontal, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(onOpen == nil || port.url == nil)
                .help(port.url.map { "Open \($0.absoluteString)" } ?? "This port has no browser address")
                .accessibilityLabel("Open port \(String(port.port)), \(port.processName)")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
