import Foundation
import GhosttyKit
import GrafttyKit

protocol HostManagedZmxSession: AnyObject {
    func start() throws
    func write(_ data: Data) throws
    func resize(cols: UInt16, rows: UInt16) throws
    func close()
}

extension NativePtySession: HostManagedZmxSession {}

final class HostManagedZmxBackend {
    typealias SessionFactory = (
        _ surface: ghostty_surface_t,
        _ spawnConfiguration: ZmxSpawnConfiguration
    ) -> HostManagedZmxSession

    enum Error: Swift.Error {
        case alreadyStarted
        case closed
        case notStarted
    }

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr, len > 0 else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        let data = Data(bytes: ptr, count: len)
        try? backend.write(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
        guard let userdata else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        try? backend.resize(cols: cols, rows: rows)
    }

    private let spawnConfiguration: ZmxSpawnConfiguration
    private let sessionFactory: SessionFactory
    private var userdataPointer: UnsafeMutableRawPointer!
    private let lock = NSLock()

    private var session: HostManagedZmxSession?
    private var isClosed = false

    init(
        spawnConfiguration: ZmxSpawnConfiguration,
        sessionFactory: @escaping SessionFactory = { surface, configuration in
            NativePtySession(
                surface: surface,
                argv: configuration.argv,
                env: configuration.env,
                workingDirectory: configuration.workingDirectory,
                spawnFailed: { _ in }
            )
        }
    ) {
        self.spawnConfiguration = spawnConfiguration
        self.sessionFactory = sessionFactory

        let userdata = HostManagedZmxBackendUserdata(backend: self)
        self.userdataPointer = Unmanaged.passRetained(userdata).toOpaque()
    }

    deinit {
        close()
        if let userdataPointer {
            Unmanaged<HostManagedZmxBackendUserdata>
                .fromOpaque(userdataPointer)
                .release()
        }
    }

    func configure(_ config: inout ghostty_surface_config_s) {
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = userdataPointer
        config.receive_buffer = Self.receiveBufferCallback
        config.receive_resize = Self.receiveResizeCallback
    }

    func start(surface: ghostty_surface_t) throws {
        lock.lock()
        if isClosed {
            lock.unlock()
            throw Error.closed
        }
        if session != nil {
            lock.unlock()
            throw Error.alreadyStarted
        }
        lock.unlock()

        let newSession = sessionFactory(surface, spawnConfiguration)

        do {
            try newSession.start()
        } catch {
            newSession.close()
            throw error
        }

        lock.lock()
        if isClosed {
            lock.unlock()
            newSession.close()
            throw Error.closed
        }
        if session != nil {
            lock.unlock()
            newSession.close()
            throw Error.alreadyStarted
        }
        session = newSession
        lock.unlock()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }

        let currentSession = try activeSession()
        try currentSession.write(data)
    }

    func close() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let currentSession = session
        session = nil
        lock.unlock()

        currentSession?.close()
    }

    var userdataForTesting: UnsafeMutableRawPointer {
        userdataPointer
    }

    private func resize(cols: UInt16, rows: UInt16) throws {
        let currentSession = try activeSession()
        try currentSession.resize(cols: cols, rows: rows)
    }

    private func activeSession() throws -> HostManagedZmxSession {
        lock.lock()
        defer { lock.unlock() }

        if isClosed {
            throw Error.closed
        }
        guard let session else {
            throw Error.notStarted
        }
        return session
    }

    private static func backend(from userdata: UnsafeMutableRawPointer) -> HostManagedZmxBackend? {
        Unmanaged<HostManagedZmxBackendUserdata>
            .fromOpaque(userdata)
            .takeUnretainedValue()
            .backend
    }
}

private final class HostManagedZmxBackendUserdata {
    weak var backend: HostManagedZmxBackend?

    init(backend: HostManagedZmxBackend) {
        self.backend = backend
    }
}
