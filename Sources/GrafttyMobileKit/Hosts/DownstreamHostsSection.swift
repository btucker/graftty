#if canImport(UIKit)
import GrafttyProtocol
import SwiftUI

/// Macs a paired Mac connects to on your behalf, which can be reconnected from
/// here. Polls only while this screen is open, not for every host all the time.
struct DownstreamHostsSection: View {
    let feed: MultiHostFeed
    @State private var connections: [(host: Host, mac: RemoteMacConnectionSummary)] = []
    @State private var reconnecting: Set<RemoteMacConnectionSummary.ID> = []

    var body: some View {
        Group {
            if !connections.isEmpty {
                Section("Remote Hosts") {
                    ForEach(connections, id: \.mac.id) { entry in
                        RemoteMacConnectionRow(remoteMac: entry.mac, isReconnecting: reconnecting.contains(entry.mac.id)) {
                            reconnect(entry.mac, through: entry.host)
                        }
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func refresh() async {
        var next: [(host: Host, mac: RemoteMacConnectionSummary)] = []
        for host in feed.hosts where feed.state.isLive(host.id) {
            guard case .remoteMacConnections(let macs)? = try? await RelayedWorktreeManagementClient.send(
                .listRemoteMacConnections, using: feed.provider(for: host)) else { continue }
            next += macs.map { (host: host, mac: $0) }
        }
        connections = next
    }

    private func reconnect(_ mac: RemoteMacConnectionSummary, through host: Host) {
        guard reconnecting.insert(mac.id).inserted else { return }
        Task {
            defer { reconnecting.remove(mac.id) }
            _ = try? await RelayedWorktreeManagementClient.send(
                .connectRemoteMac(deviceID: mac.deviceID, fingerprint: mac.fingerprint),
                using: feed.provider(for: host))
            await refresh()
        }
    }
}
#endif
