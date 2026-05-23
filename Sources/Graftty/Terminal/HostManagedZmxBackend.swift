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
        _ spawnConfiguration: ZmxSpawnConfiguration,
        _ initialSize: (cols: UInt16, rows: UInt16)?
    ) -> HostManagedZmxSession

    enum Error: Swift.Error {
        case alreadyStarted
        case closed
        case notStarted
    }

    private enum Lifecycle {
        case idle
        case starting
        case running
        case closed
    }

    /// @spec IOS-12.1
    /// Tracks user engagement since the most recent attach. While `.silent`,
    /// libghostty viewport callbacks do not propagate to the zmx PTY — the
    /// PTY's existing dims persist. The first user input flips to `.engaged`
    /// and flushes any queued resize.
    private enum AttachState {
        case silent
        case engaged
    }

    private struct PendingResize {
        let cols: UInt16
        let rows: UInt16
    }

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr, len > 0 else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        let data = Data(bytes: ptr, count: len)
        // Host-managed input that arrives before the PTY session is running is
        // intentionally dropped. SurfaceHandle sends explicit extraInitialInput
        // with write(_:) after start succeeds.
        try? backend.write(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
        guard let userdata else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        backend.receiveResize(cols: cols, rows: rows)
    }

    private let spawnConfiguration: ZmxSpawnConfiguration
    private let initialSize: (cols: UInt16, rows: UInt16)?
    private let sessionFactory: SessionFactory
    private let lock = NSLock()

    private var lifecycle: Lifecycle = .idle
    private var session: HostManagedZmxSession?
    private var pendingResize: PendingResize?
    private var attachState: AttachState = .silent
    private var lastSilentResize: PendingResize?
    private var userdataPointer: UnsafeMutableRawPointer!

    init(
        spawnConfiguration: ZmxSpawnConfiguration,
        initialSize: (cols: UInt16, rows: UInt16)? = nil,
        sessionFactory: @escaping SessionFactory = { surface, configuration, initialSize in
            NativePtySession(
                surface: surface,
                argv: configuration.argv,
                env: configuration.env,
                workingDirectory: configuration.workingDirectory,
                initialSize: initialSize,
                spawnFailed: { _ in }
            )
        }
    ) {
        self.spawnConfiguration = spawnConfiguration
        self.initialSize = initialSize
        self.sessionFactory = sessionFactory

        let userdata = HostManagedZmxBackendUserdata(backend: self)
        self.userdataPointer = Unmanaged.passRetained(userdata).toOpaque()
    }

    deinit {
        close()
        if let userdataPointer {
            fputs(
                "HostManagedZmxBackend receive userdata was not released after ghostty_surface_free\n",
                stderr
            )
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
        switch lifecycle {
        case .idle:
            // IOS-12.1: each fresh attach starts gated. Until the user
            // produces input on this surface we treat libghostty's viewport
            // callbacks as advisory — we record the last reported size but
            // do not propagate it to the zmx PTY. This avoids the
            // post-reattach width drift caused by libghostty's pre-layout
            // viewport callback shrinking the PTY.
            attachState = .silent
            lastSilentResize = nil
            lifecycle = .starting
            lock.unlock()
        case .starting, .running:
            lock.unlock()
            throw Error.alreadyStarted
        case .closed:
            lock.unlock()
            throw Error.closed
        }

        let newSession = sessionFactory(surface, spawnConfiguration, initialSize)

        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            newSession.close()
            throw Error.closed
        }
        lock.unlock()

        do {
            try newSession.start()
        } catch {
            lock.lock()
            if case .starting = lifecycle {
                lifecycle = .closed
            }
            lock.unlock()
            newSession.close()
            throw error
        }

        while true {
            lock.lock()
            switch lifecycle {
            case .closed:
                lock.unlock()
                newSession.close()
                throw Error.closed
            case .starting:
                if let resize = pendingResize {
                    pendingResize = nil
                    lock.unlock()
                    try? newSession.resize(cols: resize.cols, rows: resize.rows)
                    continue
                }
                session = newSession
                lifecycle = .running
                lock.unlock()
                return
            case .idle, .running:
                lock.unlock()
                newSession.close()
                throw Error.alreadyStarted
            }
        }
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }

        // IOS-12.1: any user input is a leadership-claim signal. Flush any
        // queued viewport size to the PTY before forwarding the bytes.
        markUserInput()

        let currentSession = try activeSession()
        try currentSession.write(data)
    }

    func close() {
        lock.lock()
        if case .closed = lifecycle {
            lock.unlock()
            return
        }
        lifecycle = .closed
        let currentSession = session
        session = nil
        pendingResize = nil
        // IOS-12.1: the next attach starts a fresh engagement window.
        attachState = .silent
        lastSilentResize = nil
        lock.unlock()

        currentSession?.close()
    }

    /// Releases the retained callback userdata after the owning surface has
    /// been freed. `receive_userdata` must not be used by libghostty after this
    /// point; callbacks are only valid until the caller completes
    /// `ghostty_surface_free`.
    func releaseReceiveUserdataAfterSurfaceFree() {
        lock.lock()
        guard let pointer = userdataPointer else {
            lock.unlock()
            return
        }
        userdataPointer = nil
        lock.unlock()

        Unmanaged<HostManagedZmxBackendUserdata>
            .fromOpaque(pointer)
            .release()
    }

    var userdataForTesting: UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        return userdataPointer
    }

    private func receiveResize(cols: UInt16, rows: UInt16) {
        let currentSession: HostManagedZmxSession?

        lock.lock()
        switch attachState {
        case .silent:
            // IOS-12.1: record but do not forward. The first user-input event
            // will flush this to the PTY via `markUserInput()`.
            lastSilentResize = PendingResize(cols: cols, rows: rows)
            lock.unlock()
            return
        case .engaged:
            break
        }
        switch lifecycle {
        case .idle, .starting:
            pendingResize = PendingResize(cols: cols, rows: rows)
            currentSession = nil
        case .running:
            currentSession = session
        case .closed:
            currentSession = nil
        }
        lock.unlock()

        try? currentSession?.resize(cols: cols, rows: rows)
    }

    /// Marks that the user has acted on the surface since the most recent
    /// attach. The first call flushes any queued `lastSilentResize` so the
    /// PTY syncs to libghostty's last-reported dims. IOS-12.1.
    private func markUserInput() {
        let flushTarget: HostManagedZmxSession?
        let flushResize: PendingResize?

        lock.lock()
        guard case .silent = attachState else {
            lock.unlock()
            return
        }
        attachState = .engaged
        flushResize = lastSilentResize
        lastSilentResize = nil
        switch lifecycle {
        case .running:
            flushTarget = session
        case .idle, .starting:
            flushTarget = nil
            if let flushResize {
                pendingResize = flushResize
            }
        case .closed:
            flushTarget = nil
        }
        lock.unlock()

        if let flushTarget, let flushResize {
            try? flushTarget.resize(cols: flushResize.cols, rows: flushResize.rows)
        }
    }

    private func activeSession() throws -> HostManagedZmxSession {
        lock.lock()
        defer { lock.unlock() }

        if case .closed = lifecycle {
            throw Error.closed
        }
        guard case .running = lifecycle, let session else {
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
