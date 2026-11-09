#if canImport(UIKit)
import GrafttyRemoteClient
import SwiftUI

/// Relay destinations belonging to one saved Mac. The picker owns polling so
/// adding parents does not start competing refresh tasks on the shared routes.
struct DownstreamHostRows: View {
    typealias Connections = DownstreamHostConnections<UUID>
    let feed: MultiHostFeed
    let hostID: UUID
    let onReconnect: (Connections.Route) -> Void
    private var connections: Connections { feed.downstreamConnections }

    var body: some View {
        ForEach(connections.routes.filter { $0.host.id == hostID }) { route in
            RemoteMacConnectionRow(remoteMac: route.target, viaHostLabel: route.host.label,
                                   isIntermediaryConnected: route.host.isConnected,
                                   isReconnecting: connections.connecting.contains(route.id)) {
                onReconnect(route)
            }
            .padding(.leading, 24)
        }
    }
}
#endif
