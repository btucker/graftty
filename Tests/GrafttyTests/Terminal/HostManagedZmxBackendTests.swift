import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("HostManagedZmxBackend — Ghostty host-managed adapter")
struct HostManagedZmxBackendTests {
    @Test func configureSetsHostManagedBackendAndReceiveCallbacks() {
        let backend = Self.makeBackend(session: FakeHostManagedSession())
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

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
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
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
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
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

    @Test func resizeCallbackBeforeStartIsAppliedAfterSessionStarts() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            100,
            31,
            1200,
            744
        )
        HostManagedZmxBackend.receiveResizeCallback(
            backend.userdataForTesting,
            120,
            40,
            1440,
            960
        )

        try backend.start(surface: Self.fakeSurface())

        #expect(session.resizes() == [Resize(cols: 120, rows: 40)])
    }

    @Test func receiveCallbacksIgnoreNilUserdataAndPointers() {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

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
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        try backend.start(surface: surface)

        #expect(session.startCount() == 1)
        #expect(observedSurfaces.values() == [surface])
        #expect(observedConfigurations.values() == [spawnConfiguration])
    }

    @Test func concurrentStartCreatesAndStartsOnlyOneSession() throws {
        let session = FakeHostManagedSession()
        let factoryCalls = LockedCounter()
        let factoryEntered = DispatchSemaphore(value: 0)
        let releaseFactory = DispatchSemaphore(value: 0)
        let backend = HostManagedZmxBackend(
            spawnConfiguration: Self.spawnConfiguration(),
            sessionFactory: { _, _ in
                _ = factoryCalls.increment()
                factoryEntered.signal()
                _ = releaseFactory.wait(timeout: .now() + 2)
                return session
            }
        )
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            try? backend.start(surface: Self.fakeSurface())
            group.leave()
        }

        #expect(factoryEntered.wait(timeout: .now() + 2) == .success)

        do {
            try backend.start(surface: Self.fakeSurface())
            Issue.record("concurrent start unexpectedly succeeded")
        } catch HostManagedZmxBackend.Error.alreadyStarted {
        } catch {
            Issue.record("concurrent start threw \(error) instead of alreadyStarted")
        }

        releaseFactory.signal()

        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(factoryCalls.value() == 1)
        #expect(session.startCount() == 1)
    }

    @Test func startFailureClosesCreatedSessionAndRethrows() {
        struct ForcedStartFailure: Error {}

        let session = FakeHostManagedSession(startError: ForcedStartFailure())
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        #expect(throws: Error.self) {
            try backend.start(surface: Self.fakeSurface())
        }

        #expect(session.startCount() == 1)
        #expect(session.closeCount() == 1)
    }

    @Test func closeRacingWithStartClosesCreatedSessionOnce() {
        let startEntered = DispatchSemaphore(value: 0)
        let releaseStart = DispatchSemaphore(value: 0)
        let session = FakeHostManagedSession(
            startHook: {
                startEntered.signal()
                _ = releaseStart.wait(timeout: .now() + 2)
            }
        )
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }

        let startFinished = DispatchSemaphore(value: 0)
        let outcomes = LockedRecorder<Bool>()
        DispatchQueue.global().async {
            outcomes.append((try? backend.start(surface: Self.fakeSurface())) != nil)
            startFinished.signal()
        }

        #expect(startEntered.wait(timeout: .now() + 2) == .success)

        backend.close()
        backend.close()
        releaseStart.signal()

        #expect(startFinished.wait(timeout: .now() + 2) == .success)
        #expect(outcomes.values() == [false])
        #expect(session.startCount() == 1)
        #expect(session.closeCount() == 1)
    }

    @Test func writeForwardsExtraInputToStartedSession() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        try backend.write(Data("after-start\n".utf8))

        #expect(session.writes() == [Data("after-start\n".utf8)])
    }

    @Test func closeIsIdempotentAndClosesOwnedSessionOnce() throws {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)
        defer { backend.releaseReceiveUserdataAfterSurfaceFree() }
        try backend.start(surface: Self.fakeSurface())

        backend.close()
        backend.close()

        #expect(session.closeCount() == 1)
    }

    @Test func releaseReceiveUserdataAfterSurfaceFreeIsIdempotentAndCallbacksWithNilAreSafe() {
        let session = FakeHostManagedSession()
        let backend = Self.makeBackend(session: session)

        backend.releaseReceiveUserdataAfterSurfaceFree()
        backend.releaseReceiveUserdataAfterSurfaceFree()

        #expect(backend.userdataForTesting == nil)
        HostManagedZmxBackend.receiveBufferCallback(nil, nil, 0)
        HostManagedZmxBackend.receiveResizeCallback(nil, 80, 24, 800, 600)
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
    private let startHook: (() -> Void)?
    private var storedWrites: [Data] = []
    private var storedResizes: [Resize] = []
    private var storedStartCount = 0
    private var storedCloseCount = 0

    init(startError: Error? = nil, startHook: (() -> Void)? = nil) {
        self.startError = startError
        self.startHook = startHook
    }

    func start() throws {
        lock.lock()
        storedStartCount += 1
        let error = startError
        let hook = startHook
        lock.unlock()

        hook?()
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

private final class LockedCounter {
    private let lock = NSLock()
    private var stored = 0

    func increment() -> Int {
        lock.lock()
        stored += 1
        let value = stored
        lock.unlock()
        return value
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
