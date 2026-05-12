import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("HostManagedZmxBackend — Ghostty host-managed adapter")
struct HostManagedZmxBackendTests {
    @Test func configureSetsHostManagedBackendAndReceiveCallbacks() {
        let backend = Self.makeBackend(session: FakeHostManagedSession())

        var config = ghostty_surface_config_new()
        backend.configure(&config)

        #expect(config.backend == GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(config.receive_userdata != nil)
        #expect(config.receive_buffer != nil)
        #expect(config.receive_resize != nil)
    }

    @Test func receiveBufferCallbackForwardsBytesToStartedSession() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        try backend.start(surface: Self.fakeSurface())

        let bytes = Array("abc".utf8)
        bytes.withUnsafeBufferPointer { ptr in
            HostManagedZmxBackend.receiveBufferCallback(
                backend.userdataForTesting,
                ptr.baseAddress,
                ptr.count
            )
        }

        #expect(session.writes() == [Data("abc".utf8)])
    }

    @Test func receiveResizeCallbackForwardsGridSizeToStartedSession() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        try backend.start(surface: Self.fakeSurface())

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            132,
            43,
            2112,
            1032
        )

        #expect(session.resizes() == [Resize(cols: 132, rows: 43)])
    }

    @Test func receiveCallbacksIgnoreNilUserdataAndPointers() {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)

        HostManagedZmxBackend.receiveBufferCallback(nil, nil, 3)
        HostManagedZmxBackend.receiveResizeCallback(nil, 80, 24, 800, 600)
        HostManagedZmxBackend.receiveBufferCallback(backend.userdataForTesting, nil, 3)

        #expect(session.writes().isEmpty)
        #expect(session.resizes().isEmpty)
    }

    @Test func startCreatesAndStartsNativeSessionFromSpawnConfigurationAndSurface() throws {
        let session = FakeHostManagedSession()
        let observedSurfaces = LockedRecorder<UnsafeMutableRawPointer>()
        let observedConfigurations = LockedRecorder<ZmxSpawnConfiguration>()
        let surface = Self.fakeSurface()
        let spawnConfiguration = Self.spawnConfiguration()
        let backend = HostManagedZmxBackend(
            spawnConfiguration: spawnConfiguration,
            sessionFactory: { startedSurface, configuration in
                observedSurfaces.append(startedSurface)
                observedConfigurations.append(configuration)
                return session
            }
        )

        try backend.start(surface: surface)

        #expect(session.startCount() == 1)
        #expect(observedSurfaces.values() == [surface])
        #expect(observedConfigurations.values() == [spawnConfiguration])
    }

    @Test func startFailureClosesCreatedSessionAndRethrows() {
        struct ForcedStartFailure: Error {}

        let session = FakeHostManagedSession(startError: ForcedStartFailure())
        let backend = Self.makeBackend(session: session)

        #expect(throws: Error.self) {
            try backend.start(surface: Self.fakeSurface())
        }

        #expect(session.startCount() == 1)
        #expect(session.closeCount() == 1)
    }

    @Test func writeForwardsExtraInputToStartedSession() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        try backend.start(surface: Self.fakeSurface())

        try backend.write(Data("after-start\n".utf8))

        #expect(session.writes() == [Data("after-start\n".utf8)])
    }

    @Test func closeIsIdempotentAndClosesOwnedSessionOnce() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        try backend.start(surface: Self.fakeSurface())

        backend.close()
        backend.close()

        #expect(session.closeCount() == 1)
    }

    private static func makeBackend(session: FakeHostManagedSession) -> HostManagedZmxBackend {
        HostManagedZmxBackend(
            spawnConfiguration: spawnConfiguration(),
            sessionFactory: { _, _ in session }
        )
    }

    private static func spawnConfiguration() -> ZmxSpawnConfiguration {
        ZmxSpawnConfiguration(
            sessionName: "graftty-test",
            argv: ["/tmp/zmx", "attach", "graftty-test", "/bin/zsh"],
            env: ["ZMX_DIR": "/tmp/zmx-dir"],
            workingDirectory: URL(fileURLWithPath: "/tmp/worktree", isDirectory: true)
        )
    }

    private static func fakeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer(bitPattern: 0x1234)!
    }
}

private struct Resize: Equatable {
    let cols: UInt16
    let rows: UInt16
}

private final class FakeHostManagedSession: HostManagedZmxSession {
    private let lock = NSLock()
    private let startError: Error?
    private var storedWrites: [Data] = []
    private var storedResizes: [Resize] = []
    private var storedStartCount = 0
    private var storedCloseCount = 0

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func start() throws {
        lock.lock()
        storedStartCount += 1
        let error = startError
        lock.unlock()

        if let error {
            throw error
        }
    }

    func write(_ data: Data) throws {
        lock.lock()
        storedWrites.append(data)
        lock.unlock()
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        lock.lock()
        storedResizes.append(Resize(cols: cols, rows: rows))
        lock.unlock()
    }

    func close() {
        lock.lock()
        storedCloseCount += 1
        lock.unlock()
    }

    func writes() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return storedWrites
    }

    func resizes() -> [Resize] {
        lock.lock()
        defer { lock.unlock() }
        return storedResizes
    }

    func startCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedStartCount
    }

    func closeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCount
    }
}

private final class LockedRecorder<Value> {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    func values() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
