import GrafttyProtocol

/// Maps an authenticated `RemoteDeviceID` to a closable live SSH connection.
/// Single-connection today (`WebRTCHostAgent`), but keyed by peer so a
/// multi-connection host slots in without reshaping callers.
public actor SSHConnectionRegistry {
    /// Opaque identity for one `register` call's entry. `deregister`
    /// carries the token it was handed at registration time and only
    /// removes the stored entry if the token still matches — this is
    /// what keeps a fire-and-forget `deregister` Task (spawned from
    /// `WebRTCHostAgent.close()`) from wiping out a DIFFERENT, newer
    /// registration for the same `RemoteDeviceID` that replaced it in
    /// the meantime (reconnect race — see `SSHConnectionRegistryTests`).
    ///
    /// A monotonic counter rather than a `UUID` — this actor is the only
    /// writer, so a simple increment is enough to make every registration
    /// distinguishable, and it keeps `deregister`'s equality check trivial.
    public struct RegistrationToken: Equatable, Sendable {
        fileprivate let rawValue: UInt64
    }

    private struct Entry {
        let token: RegistrationToken
        let close: @Sendable () async -> Void
    }

    private var entries: [RemoteDeviceID: Entry] = [:]
    private var nextTokenValue: UInt64 = 0

    public init() {}

    /// Register the peer's connection with a close action (the agent passes
    /// a closure that closes the SSH parent channel / transport). Replacing
    /// an existing entry for the same device closes the old one first, then
    /// installs a fresh token for the new entry — the old connection's own
    /// (possibly still in-flight) `deregister` call carries the OLD token
    /// and so can't touch the replacement.
    ///
    /// Returns the token identifying THIS registration; callers hold on to
    /// it and pass it back to `deregister(deviceID:token:)`.
    @discardableResult
    public func register(
        deviceID: RemoteDeviceID,
        close: @escaping @Sendable () async -> Void
    ) async -> RegistrationToken {
        if let previous = entries[deviceID] {
            await previous.close()
        }
        let token = RegistrationToken(rawValue: nextTokenValue)
        nextTokenValue += 1
        entries[deviceID] = Entry(token: token, close: close)
        return token
    }

    /// Remove the peer's entry, but ONLY if it's still the one identified
    /// by `token`. A stale caller (e.g. a connection that already lost a
    /// register-replace race, or was already revoked) holds an old token
    /// and this becomes a no-op rather than clobbering whatever registered
    /// after it.
    public func deregister(deviceID: RemoteDeviceID, token: RegistrationToken) {
        guard entries[deviceID]?.token == token else { return }
        entries[deviceID] = nil
    }

    /// Close and remove the peer's connection if present (idempotent — a
    /// second revoke, or a revoke of a never-connected peer, is a no-op).
    /// Unconditional on token — revocation is peer-wide and must kill
    /// whatever connection is CURRENTLY registered, not a specific
    /// generation of it.
    public func revoke(deviceID: RemoteDeviceID) async {
        guard let entry = entries.removeValue(forKey: deviceID) else { return }
        await entry.close()
    }

    public var count: Int { entries.count }
}
