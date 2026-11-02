import Foundation
import SwiftUI

/// Agent creation remains available independently of a workspace's tab strip.
public struct NewAgentMenu: View {
    private let launch: @MainActor (String?, UUID) async throws -> Void
    @State private var launching = false
    @State private var failure: String?

    public init(launch: @escaping @MainActor (String?, UUID) async throws -> Void) { self.launch = launch }

    public var body: some View {
        Menu {
            Button("New default agent") { start(nil) }
            Divider()
            Button { start("codex") } label: {
                Label { Text("New Codex agent") } icon: { AgentProviderIcon(provider: "codex") }
            }
            Button { start("claude") } label: {
                Label { Text("New Claude agent") } icon: { AgentProviderIcon(provider: "claude") }
            }
        } label: {
            Label(launching ? "Starting agent…" : "New agent", systemImage: "plus")
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                #endif
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
