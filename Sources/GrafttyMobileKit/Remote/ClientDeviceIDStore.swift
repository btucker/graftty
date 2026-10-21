#if canImport(UIKit)
import Foundation
import GrafttyProtocol

// MARK: - ClientDeviceIDStore

/// Persists the client's stable `RemoteDeviceID` in `client-device-id.json`
/// so pairing requests and pinned-host records identify the same device
/// across launches; see `RemoteDeviceIDStore` for the format.
public typealias ClientDeviceIDStore = RemoteDeviceIDStore<ClientDeviceIDFile>

public enum ClientDeviceIDFile: RemoteIdentityFileLocation {
    public static let fileName = "client-device-id.json"

    /// Shared with the other remote-identity stores.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty")
            .appendingPathComponent("Remote")
    }
}
#endif
