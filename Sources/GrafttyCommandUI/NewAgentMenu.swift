import Foundation
import SwiftUI

/// Agent creation remains available independently of a workspace's tab strip.
public struct NewAgentMenu: View {
    private let launch: @MainActor (String?, UUID) async throws -> Void
    private let menuContent: AnyView?
    private let label: AnyView?
    @State private var launching = false
    @State private var failure: String?

    public init(menuContent: AnyView? = nil, label: AnyView? = nil,
                launch: @escaping @MainActor (String?, UUID) async throws -> Void) {
        self.menuContent = menuContent
        self.label = label
        self.launch = launch
    }

    public var body: some View {
        Menu {
            if let menuContent {
                menuContent
                Divider()
            }
            Button("New default agent") { start(nil) }
            Divider()
            Button { start("codex") } label: {
                Label { Text("New Codex agent") } icon: { AgentProviderIcon(provider: "codex") }
            }
            Button { start("claude") } label: {
                Label { Text("New Claude agent") } icon: { AgentProviderIcon(provider: "claude") }
            }
        } label: {
            if let label {
                label.opacity(launching ? 0.3 : 1)
                    .overlay { if launching { ProgressView() } }
            } else {
                Label(launching ? "Starting agent…" : "New agent", systemImage: "plus")
                #if os(iOS)
                // Native menu styling can inset the accessible bounds by a device pixel.
                .frame(minWidth: 48, minHeight: 48)
                #endif
            }
        }
        .disabled(launching)
        .accessibilityIdentifier("workspace.agent.add")
        .alert("Could not start agent", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func start(_ provider: String?) {
        guard !launching else { return }
        launching = true
        Task { @MainActor in
            defer { launching = false }
            do { try await launch(provider, UUID()) }
            catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}

public struct AgentLaunchError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
