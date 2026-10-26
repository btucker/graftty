import Foundation
import Testing
@testable import GrafttyProtocol
import GrafttyTestSupport

@Suite("RemoteIdentityFileStore")
struct RemoteIdentityFileStoreTests {
    private enum DeviceFile: RemoteIdentityFileLocation {
        static let fileName = "device-id.json"
    }

    @Test("@spec PERSIST-5.8: If a remote device ID file cannot be read for a reason other than absence or malformed contents, then the application shall throw the read error and preserve the persisted identity.")
    func unreadableDeviceIDIsPreserved() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = RemoteDeviceIDStore<DeviceFile>(directory: dir)
        let original = try store.loadOrGenerateAndPersist()
        let url = dir.appendingPathComponent(DeviceFile.fileName)
        let bytes = try Data(contentsOf: url)
        // Inject the read failure so this also exercises EACCES when Linux CI runs as root.
        let denied = RemoteDeviceIDStore<DeviceFile>(directory: dir, readData: { _ in
            throw CocoaError(.fileReadNoPermission)
        })
        #expect(throws: CocoaError(.fileReadNoPermission)) { try denied.loadOrGenerateAndPersist() }

        #expect(try Data(contentsOf: url) == bytes)
        #expect(try store.loadOrGenerateAndPersist() == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [DeviceFile.fileName])
    }
}
