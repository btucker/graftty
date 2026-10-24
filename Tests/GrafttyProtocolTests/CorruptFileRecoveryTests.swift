import Foundation
import Testing
@testable import GrafttyProtocol
import GrafttyTestSupport

@Suite("@spec PERSIST-5.12: If a corrupt file cannot be moved aside, then the application shall preserve it and surface the failure before allowing a replacement write.")
@MainActor
struct CorruptFileRecoveryTests {
    private struct MoveDenied: Error {}
    private enum IdentityFile: RemoteIdentityFileLocation {
        static let fileName = "identity.json"
    }

    private final class MoveControl: @unchecked Sendable {
        private let lock = NSLock()
        private var denied = true
        func allow() { lock.withLock { denied = false } }
        func move(_ from: URL, _ to: URL) throws {
            if lock.withLock({ denied }) { throw MoveDenied() }
            try FileManager.default.moveItem(at: from, to: to)
        }
    }

    @Test("a backup collision is reported and preserves both files")
    func collisionSurfaces() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("x.json")
        let backup = dir.appendingPathComponent("x.json.corrupt.100000")
        let original = Data("broken JSON".utf8)
        let previousBackup = Data("previous evidence".utf8)
        try original.write(to: url)
        try previousBackup.write(to: backup)
        let file = JSONFileStore<String>(fileURL: url)

        #expect(throws: (any Error).self) {
            try file.moveAsideCorruptFile(now: Date(timeIntervalSince1970: 100))
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try Data(contentsOf: backup) == previousBackup)
    }

    @Test("identity regeneration stops when backup fails", arguments: [false, true])
    func identityBackupFailure(_ key: Bool) throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent(IdentityFile.fileName)
        let original = Data("{broken".utf8)
        try original.write(to: url)
        if key {
            let store = RemoteIdentityKeyStore<IdentityFile>(directory: dir,
                readData: { try Data(contentsOf: $0) }, moveCorruptFile: { _, _ in throw MoveDenied() })
            #expect(throws: MoveDenied.self) { try store.loadOrGenerateAndPersist() }
        } else {
            let store = RemoteDeviceIDStore<IdentityFile>(directory: dir,
                readData: { try Data(contentsOf: $0) }, moveCorruptFile: { _, _ in throw MoveDenied() })
            #expect(throws: MoveDenied.self) { try store.loadOrGenerateAndPersist() }
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("a list write retries failed recovery and preserves evidence before publishing")
    func listRecoveryMustSucceedBeforeWrite() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rows.json")
        let control = MoveControl()
        var file = JSONFileStore<[String]>(fileURL: url)
        file.moveItem = { try control.move($0, $1) }
        let original = Data("{broken".utf8)
        try file.write(original)
        let store = ObservableListStore(file: file, corruptFile: .moveAside, areInIncreasingOrder: <)
        await store.loadIfNeeded()

        #expect(throws: MoveDenied.self) { try store.write(["fresh"]) }
        #expect(store.elements.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        control.allow()
        try store.write(["fresh"])
        try store.write(["updated"])
        #expect(try file.load() == ["updated"])
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("rows.json.corrupt.") }
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup) == original)
    }
}
