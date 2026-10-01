import Foundation
import GrafttyProtocol
import NIOCore

/// Scoped to one peer-connection lifecycle. A token binds a history channel
/// to exactly one terminal on the other SSH transport, owned by the same peer.
public final class BulkTerminalChannels: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [String: (RemoteDeviceID, Channel)] = [:]

    public init() {}

    func register(token: String, deviceID: RemoteDeviceID, channel: Channel) -> Bool {
        lock.lock()
        guard UUID(uuidString: token) != nil, channels[token] == nil, channels.count < 64 else {
            lock.unlock()
            return false
        }
        channels[token] = (deviceID, channel)
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            if self.channels[token]?.1 === channel { self.channels.removeValue(forKey: token) }
            self.lock.unlock()
        }
        return true
    }

    func claim(token: String, deviceID: RemoteDeviceID) -> Channel? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = channels[token], entry.0 == deviceID else { return nil }
        channels.removeValue(forKey: token)
        return entry.1
    }
}
