import Foundation
import Testing
@testable import GrafttyProtocol
import GrafttyTestSupport

@Suite("@spec PERSIST-5.10: When remote identity stores in one process refer to the same destination path, the application shall serialize their complete read-and-generate transactions so they return the same persisted identity.")
struct RemoteIdentityStoreConcurrencyTests {
    private enum KeyFile: RemoteIdentityFileLocation {
        static let fileName = "key.json"
    }

    private enum DeviceFile: RemoteIdentityFileLocation {
        static let fileName = "device.json"
    }

    private final class ReadGate: @unchecked Sendable {
        let entered: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation
        let release = DispatchSemaphore(value: 0)

        init() {
            (entered, continuation) = AsyncStream.makeStream()
        }

        func read(_ url: URL) throws -> Data {
            let result = Result { try Data(contentsOf: url) }
            continuation.yield(())
            release.wait()
            return try result.get()
        }
    }

    @Test("two key stores, including a symlink alias, generate one key")
    func keyStoresShareTransaction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        let gate = ReadGate()
        let first = RemoteIdentityKeyStore<KeyFile>(directory: dir, readData: { try gate.read($0) })
        let second = RemoteIdentityKeyStore<KeyFile>(directory: alias)

        try await assertOneIdentity(gate: gate, secondLock: second.lock,
            first: { try first.loadOrGenerateAndPersist().rawRepresentation },
            second: { try second.loadOrGenerateAndPersist().rawRepresentation },
            reloaded: { try RemoteIdentityKeyStore<KeyFile>(directory: dir).loadOrGenerateAndPersist().rawRepresentation })
    }

    @Test("two device ID stores generate one ID")
    func deviceStoresShareTransaction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let gate = ReadGate()
        let first = RemoteDeviceIDStore<DeviceFile>(directory: dir, readData: { try gate.read($0) })
        let second = RemoteDeviceIDStore<DeviceFile>(directory: dir)

        try await assertOneIdentity(gate: gate, secondLock: second.lock,
            first: { try first.loadOrGenerateAndPersist() },
            second: { try second.loadOrGenerateAndPersist() },
            reloaded: { try RemoteDeviceIDStore<DeviceFile>(directory: dir).loadOrGenerateAndPersist() })
    }

    @Test("replacing a file symlink does not split live stores across different locks")
    func replacingFileSymlinkKeepsTransactionLock() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("target.json")
        try Data("original symlink target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent(KeyFile.fileName), withDestinationURL: target)
        let gate = ReadGate()
        let first = RemoteIdentityKeyStore<KeyFile>(directory: dir, readData: { try gate.read($0) })
        // Atomic publication replaces the symlink itself. The live store must
        // still share its lock with instances created after that replacement.
        _ = try first.generateAndPersist()
        try first.reset()
        let second = RemoteIdentityKeyStore<KeyFile>(directory: dir)

        try await assertOneIdentity(gate: gate, secondLock: second.lock,
            first: { try first.loadOrGenerateAndPersist().rawRepresentation },
            second: { try second.loadOrGenerateAndPersist().rawRepresentation },
            reloaded: { try RemoteIdentityKeyStore<KeyFile>(directory: dir).loadOrGenerateAndPersist().rawRepresentation })
    }

    @Test("directory aliases share a lock before the identity directory exists")
    func missingDirectoryAliasesShareTransaction() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: dir)
        let directory = dir.appendingPathComponent("not-created-yet")
        let gate = ReadGate()
        let first = RemoteDeviceIDStore<DeviceFile>(directory: directory, readData: { try gate.read($0) })
        let second = RemoteDeviceIDStore<DeviceFile>(directory: alias.appendingPathComponent("not-created-yet"))

        try await assertOneIdentity(gate: gate, secondLock: second.lock,
            first: { try first.loadOrGenerateAndPersist() },
            second: { try second.loadOrGenerateAndPersist() },
            reloaded: { try RemoteDeviceIDStore<DeviceFile>(directory: directory).loadOrGenerateAndPersist() })
    }

    private func assertOneIdentity<Value: Equatable & Sendable>(
        gate: ReadGate,
        secondLock: NSLock,
        first: @escaping @Sendable () throws -> Value,
        second: () throws -> Value,
        reloaded: () throws -> Value
    ) async throws {
        // The synchronous reader deliberately blocks. Keep it off Swift's
        // cooperative executor so two-CPU Linux runs can resume the test.
        let pending = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                DispatchQueue.global().async {
                    continuation.resume(with: Result { try first() })
                }
            }
        }
        defer { gate.release.signal() }
        var events = gate.entered.makeAsyncIterator()
        _ = await events.next()

        // If the second lock is independent, complete its whole operation while
        // the first still holds a cached "missing" read. This forces the defect.
        let raced = try loadIfUnlocked(secondLock, load: second)
        gate.release.signal()
        let firstValue = try await pending.value
        let secondValue = try raced ?? second()
        #expect(raced == nil, "The second transaction must wait for the first.")
        #expect(secondValue == firstValue)
        #expect(try reloaded() == firstValue)
    }

    private func loadIfUnlocked<Value>(_ lock: NSLock, load: () throws -> Value) throws -> Value? {
        guard lock.try() else { return nil }
        lock.unlock()
        return try load()
    }
}
