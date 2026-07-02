import GrafttyProtocol

/// Maps an authenticated `RemoteDeviceID` to a closable live SSH connection.
/// Single-connection today (`WebRTCHostAgent`), but keyed by peer so a
/// multi-connection host slots in without reshaping callers.
public actor SSHConnectionRegistry {
    private var closers: [RemoteDeviceID: @Sendable () async -> Void] = [:]

    public init() {}

    /// Register the peer's connection with a close action (the agent passes
    /// a closure that closes the SSH parent channel / transport). Replacing
    /// an existing entry for the same device closes the old one first.
    public func register(deviceID: RemoteDeviceID, close: @escaping @Sendable () async -> Void) async {
        if let previous = closers[deviceID] {
            await previous()
        }
        closers[deviceID] = close
    }

    public func deregister(deviceID: RemoteDeviceID) {
        closers[deviceID] = nil
    }

    /// Close and remove the peer's connection if present (idempotent — a
    /// second revoke, or a revoke of a never-connected peer, is a no-op).
    public func revoke(deviceID: RemoteDeviceID) async {
        guard let close = closers.removeValue(forKey: deviceID) else { return }
        await close()
    }

    public var count: Int { closers.count }
}
