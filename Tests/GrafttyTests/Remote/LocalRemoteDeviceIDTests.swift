import Foundation
@testable import GrafttyProtocol
import GrafttyTestSupport
import Testing
@testable import Graftty
@testable import GrafttyKit

/// A store in `directory` holding `persisted`, whose first `failures` reads
/// fail with a permission error.
func flakyHostDeviceIDStore(
    in directory: URL,
    persisted: RemoteDeviceID,
    failures: Int
) throws -> HostDeviceIDStore {
    try Data(#"{"version":1,"deviceID":{"value":"\#(persisted.value)"}}"#.utf8)
        .write(to: directory.appendingPathComponent(HostDeviceIDFile.fileName))
    return HostDeviceIDStore(directory: directory, readData: readDataFailingFirst(failures))
}

@Suite("Local remote device ID")
@MainActor
struct LocalRemoteDeviceIDTests {
    @Test("@spec REMOTE-1.14: If the host device-ID store cannot load or persist the stable device ID, then the application shall surface the store error to the Mac caller rather than generate a replacement device ID.")
    func storeErrorPropagatesWithoutMintingAnID() throws {
        let directory = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persisted = RemoteDeviceID(value: "persisted-mac")
        let store = try flakyHostDeviceIDStore(in: directory, persisted: persisted, failures: 1)

        #expect(throws: CocoaError(.fileReadNoPermission)) {
            try AppServices.localRemoteDeviceID(store: store)
        }
        #expect(try AppServices.localRemoteDeviceID(store: store) == persisted)
    }

    @Test("@spec REMOTE-1.17: If paired-device access cannot start because the host device-ID store is unreadable, then the application shall report that the device ID could not be read rather than blame a port conflict.")
    func unreadableDeviceIDStartupMessageNamesTheDeviceID() {
        let message = GrafttyApp.remoteAccessStartupMessage(
            for: AppServices.RemoteMacAccessServiceError.deviceIDUnavailable(CocoaError(.fileReadNoPermission))
        )

        #expect(message.contains("device ID"))
        #expect(!message.contains("Quit the other process"))
    }
}
