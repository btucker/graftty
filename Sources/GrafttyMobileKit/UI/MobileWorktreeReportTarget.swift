#if canImport(UIKit)
import SwiftUI
import GrafttyCommandUI
import GrafttyProtocol

struct MobileWorktreeReportContent: View {
    let context: SidebarWorktreeContext
    let onOpen: () async -> Bool
    let onDismiss: () -> Void
    let onClose: () -> Void
    var host: Host? = nil
    var remoteConnectionProvider: RemoteConnectionProvider? = nil
    @State private var browserURL: PortPreview?
    @State private var openingPort = false
    @State private var portError: String?
    @State private var portOpenTask: Task<Void, Never>?

    init(context: SidebarWorktreeContext, onOpen: @escaping () async -> Bool,
         onDismiss: @escaping () -> Void, onClose: @escaping () -> Void,
         host: Host? = nil, remoteConnectionProvider: RemoteConnectionProvider? = nil) {
        self.context = context
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        self.onClose = onClose
        self.host = host
        self.remoteConnectionProvider = remoteConnectionProvider
    }

    private struct PortPreview: Identifiable {
        let id = UUID()
        let url: URL
    }

    var body: some View {
        SidebarWorktreeReport(context: context, onOpen: onOpen, onDismiss: onDismiss, onClose: onClose,
            onOpenPort: host != nil && remoteConnectionProvider != nil ? openPort : nil)
            .frame(idealWidth: 380, idealHeight: 440)
            .frame(maxHeight: 600)
            .overlay { if openingPort { ProgressView("Opening port…").padding().background(.regularMaterial, in: Capsule()) } }
            .sheet(item: $browserURL) { preview in
                if let host, let remoteConnectionProvider {
                    HostBrowserView(url: preview.url, host: host, connectionProvider: remoteConnectionProvider)
                }
            }
            .alert("Could not open port", isPresented: Binding(
                get: { portError != nil }, set: { if !$0 { portError = nil } }
            )) { Button("OK") { portError = nil } } message: { Text(portError ?? "") }
            .onDisappear { portOpenTask?.cancel() }
    }

    private func openPort(_ port: WorktreePort) {
        guard !openingPort else { return }
        openingPort = true
        portOpenTask = Task { @MainActor in
            defer { openingPort = false }
            do {
                let url = try await WorktreePortClient.open(port, in: context.worktree) { request in
                    try await RelayedWorktreeManagementClient.send(request, using: remoteConnectionProvider)
                }
                guard !Task.isCancelled else { return }
                browserURL = PortPreview(url: url)
            } catch { if !Task.isCancelled { portError = error.localizedDescription } }
        }
    }
}

/// A sibling of the terminal tap target so preview never also opens a pane.
struct MobileWorktreeReportButton: View {
    let worktreeName: String
    let onReport: () -> Void

    func activate() { onReport() }

    var body: some View {
        Button(action: activate) {
            Image(systemName: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Show report for \(worktreeName)")
    }
}

/// A row's tap target. Touch and hold belongs to the row's menu (LAYOUT-2.141).
struct MobileWorktreeReportTarget<Content: View>: View {
    @Environment(\.editMode) private var editMode
    let onOpen: () -> Void
    let onReport: () -> Void
    @ViewBuilder let content: () -> Content

    func open() { onOpen() }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .gesture(TapGesture().onEnded { open() },
                     including: editMode?.wrappedValue.isEditing == true ? .none : .all)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Show report") { onReport() }
    }
}

/// What touching and holding a worktree row offers (LAYOUT-2.141).
struct MobileWorktreeRowMenu: View {
    enum Action: Equatable { case dismissRequest, showReport }

    let context: SidebarWorktreeContext
    let onReport: () -> Void
    let onDismiss: () -> Void

    var actions: [Action] {
        (SidebarAttentionDismissal.isAvailable(context) ? [.dismissRequest] : []) + [.showReport]
    }

    func perform(_ action: Action) {
        switch action {
        case .dismissRequest: onDismiss()
        case .showReport: onReport()
        }
    }

    var body: some View {
        ForEach(actions, id: \.self) { action in
            switch action {
            case .dismissRequest:
                Button(SidebarAttentionDismissal.title, systemImage: "bell.slash") { perform(action) }
            case .showReport:
                Button("Show Report", systemImage: "doc.text") { perform(action) }
            }
        }
    }
}
#endif
