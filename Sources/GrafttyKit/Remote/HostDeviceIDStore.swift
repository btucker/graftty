import Foundation
import GrafttyProtocol

// MARK: - HostDeviceIDStore

/// Persists the host's stable `RemoteDeviceID` in `host-device-id.json` so
/// pairing payloads and trusted-peer records identify the same Mac across
/// launches; see `RemoteDeviceIDStore` for the format.
public typealias HostDeviceIDStore = RemoteDeviceIDStore<HostDeviceIDFile>

public enum HostDeviceIDFile: RemoteIdentityFileLocation {
    public static let fileName = "host-device-id.json"

    /// Shared with the other remote-identity stores.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }
}

/// Generic types cannot hold static stored properties, so `shared` is
/// backed by this lazily initialised global.
private let sharedHostDeviceIDStore = HostDeviceIDStore(directory: HostDeviceIDFile.defaultDirectory)

extension RemoteDeviceIDStore where Location == HostDeviceIDFile {
    /// The single production store used by every Mac-side role. A Mac can
    /// simultaneously be a host and a client of another Mac; both roles must
    /// present the same device ID or a pairing created by one subsystem will
    /// not authenticate in another.
    public static var shared: HostDeviceIDStore { sharedHostDeviceIDStore }
}
