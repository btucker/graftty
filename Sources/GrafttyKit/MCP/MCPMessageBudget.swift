import Foundation
import GrafttyProtocol

/// Track only JSON-RPC IDs and ages, never params or results. The SDK owns MCP
/// semantics; these transport limits apply equally to calls and callbacks.
struct MCPMessageBudget {
    enum Direction { case worker, parent }
    private var workerRequests: [Data: ContinuousClock.Instant] = [:]
    private var parentRequests: [Data: ContinuousClock.Instant] = [:]

    mutating func record(_ bytes: Data, from direction: Direction, now: ContinuousClock.Instant = .now) throws {
        guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw MCPProxyError.invalidRequest }
        guard let id = value["id"], !(id is NSNull) else { return }
        let key = try JSONSerialization.data(withJSONObject: id, options: [.fragmentsAllowed, .sortedKeys])
        if value["method"] != nil {
            switch direction {
            case .worker:
                guard workerRequests[key] == nil else { throw MCPProxyError.invalidRequest }
                guard workerRequests.count < 64 else { throw MCPProxyError.overloaded }
                workerRequests[key] = now
            case .parent:
                guard parentRequests[key] == nil else { throw MCPProxyError.invalidRequest }
                guard parentRequests.count < 64 else { throw MCPProxyError.overloaded }
                parentRequests[key] = now
            }
        } else {
            switch direction {
            case .worker: parentRequests[key] = nil
            case .parent: workerRequests[key] = nil
            }
        }
    }

    func hasExpired(at now: ContinuousClock.Instant = .now) -> Bool {
        workerRequests.values.contains { $0.duration(to: now) >= .seconds(120) }
            || parentRequests.values.contains { $0.duration(to: now) >= .seconds(120) }
    }
}
