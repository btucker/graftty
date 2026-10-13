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

/// An exclusive gesture keeps a recognized hold from also opening a terminal.
struct MobileWorktreeReportTarget<Content: View>: View {
    static var holdDuration: Double { 0.5 }
    @Environment(\.editMode) private var editMode
    let onOpen: () -> Void
    let onReport: () -> Void
    @ViewBuilder let content: () -> Content

    func activate(_ value: ExclusiveGesture<LongPressGesture, TapGesture>.Value) {
        switch value {
        case .first(true): onReport()
        case .first(false): break
        case .second: onOpen()
        }
    }

    var body: some View {
        content()
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: 10)
                    .onEnded { activate(.first($0)) }
                    .exclusively(before: TapGesture().onEnded { activate(.second($0)) }),
                including: editMode?.wrappedValue.isEditing == true ? .none : .all
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { onOpen() }
            .accessibilityAction(named: "Show report") { onReport() }
    }
}
#endif
