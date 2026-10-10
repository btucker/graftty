import Foundation
import Network
import GrafttyProtocol

/// Resolve only the advertised pane on this connection, never an origin behind a relay.
struct RemoteWorktreePortTarget {
    enum Failure: LocalizedError {
        case unavailable, relayed, notLoopback
        var errorDescription: String? {
            switch self {
            case .unavailable: "This port is no longer available on the connected host."
            case .relayed: "Connect directly to the owning host to forward this port."
            case .notLoopback: "This server has no localhost listener. Configure it to listen on localhost or all interfaces."
            }
        }
    }
    let host: String
    let port: Int
    init(worktree: WorktreePanes, sessionName: String, binding: PortBinding) throws {
        guard (worktree.origin?.relayDepth ?? 0) == 0 else { throw Failure.relayed }
        guard worktree.state == .running, worktree.layout?.leaves.contains(where: { $0.sessionName == sessionName }) == true,
              worktree.portBindings?[sessionName]?.contains(binding) == true, binding.port > 0 else { throw Failure.unavailable }
        guard let host = binding.targetHost,
              host == "::1" || IPv4Address(host)?.rawValue.first == 127 else { throw Failure.notLoopback }
        self.host = host
        self.port = Int(binding.port)
    }
}
