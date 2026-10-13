import GrafttyProtocol

public typealias PortBinding = GrafttyProtocol.PortBinding
public typealias BindScope = GrafttyProtocol.BindScope

extension PortBinding {
    public static func worktreePorts(from bindings: [PortBinding]) -> [WorktreePort] {
        var grouped: [UInt16: PortBinding] = [:]
        for binding in bindings where binding.port > 0 {
            if let existing = grouped[binding.port] {
                let process = existing.pid < binding.pid || (existing.pid == binding.pid && existing.host <= binding.host)
                    ? existing : binding
                grouped[binding.port] = PortBinding(port: binding.port,
                    scope: existing.scope == .lan || binding.scope == .lan ? .lan : .loopback,
                    processName: process.processName, pid: process.pid, host: process.host)
            } else {
                grouped[binding.port] = binding
            }
        }
        return grouped.values.sorted { $0.port < $1.port }.map {
            WorktreePort(port: $0.port, scope: $0.scope == .lan ? .lan : .loopback, processName: $0.processName, host: $0.host)
        }
    }
}
