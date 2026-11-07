#if canImport(UIKit)
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI

/// Macs a paired Mac connects to on your behalf, which can be reconnected from
/// here. Polls only while this screen is open, not for every host all the time.
struct DownstreamHostsSection: View {
    private typealias Connections = DownstreamHostConnections<UUID>
    let feed: MultiHostFeed
    private var connections: Connections { feed.downstreamConnections }

    private var hosts: [Connections.Host] {
        feed.hosts.map { .init(id: $0.id, label: $0.label, isConnected: feed.state.isLive($0.id)) }
    }

    var body: some View {
        Group {
            if !connections.routes.isEmpty {
                Section("Through another Mac") {
                    ForEach(connections.routes) { route in
                        RemoteMacConnectionRow(remoteMac: route.target, viaHostLabel: route.host.label,
                                               isIntermediaryConnected: route.host.isConnected,
                                               isReconnecting: connections.connecting.contains(route.id)) {
                            Task {
                                await connections.connect(route, send: send)
                                await refresh()
                            }
                        }
                    }
                }
            }
        }
        .alert("Couldn't connect host", isPresented: Binding(
            get: { connections.error != nil },
            set: { if !$0 { connections.error = nil } }
        )) {
            Button("OK", role: .cancel) { connections.error = nil }
        } message: { Text(connections.error ?? "") }
        .task(id: hosts) {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refresh() async {
        await connections.refresh(hosts: hosts, send: send)
    }

    private func send(_ hostID: UUID, _ request: WorktreeManagementRequest) async throws -> WorktreeManagementResponse {
        guard let host = feed.host(id: hostID) else {
            throw RelayedWorktreeManagementClient.ClientError.pairedConnectionUnavailable
        }
        let isConnect: Bool
        if case .connectRemoteMac = request { isConnect = true } else { isConnect = false }
        return try await RelayedWorktreeManagementClient.send(request, using: feed.provider(for: host, wake: isConnect ? .now : .never))
    }
}
#endif
