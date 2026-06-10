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
    /// libghostty viewport callbacks propagate to the zmx PTY only when
    /// layout has settled AND no remote client is attached to the session
    /// (TERM-11.2); otherwise they are recorded and the PTY's existing dims
    /// persist. The first user input flips to `.engaged` and syncs the PTY
    /// to the current grid (TERM-11.3).
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
        //
        // IOS-12.1: when the caller is currently inside a
        // `withProgrammaticInput` scope (e.g. `SurfaceHandle.pressReturn`
        // invoked from the send-pane IPC), the bytes libghostty emits
        // for the synthesized key event should NOT engage the silent
        // gate — they're automation, not a human keystroke.
        try? backend.write(data, claimEngagement: !backend.isProgrammaticInputActive)
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

    /// Reentrant counter tracking active `withProgrammaticInput` scopes.
    /// While > 0, `receiveBufferCallback` treats the inbound bytes as
    /// automation and passes `claimEngagement: false` to `write`.
    /// IOS-12.1.
    private var programmaticInputDepth: Int = 0

    /// TERM-11.x gating inputs. `hasRemoteClient` is injected at init
    /// (default false — direct-shell/test backends have no remote peers).
    /// The surface-sync closures are bound by SurfaceHandle after
    /// ghostty_surface_new succeeds, before start(surface:).
    private let hasRemoteClient: () -> Bool
    private var currentGridSize: () -> (cols: UInt16, rows: UInt16)? = { nil }
    private var requestRefresh: () -> Void = {}

    /// Flips true (once) when the owning NSView first receives a nonzero
    /// frame. While still `.silent`, pre-settle viewport callbacks are
    /// never forwarded — they are libghostty pre-layout noise (the
    /// original PR #201 bug). An engaged pane bypasses this gate.
    private var layoutSettled = false

    init(
        spawnConfiguration: ZmxSpawnConfiguration,
        initialSize: (cols: UInt16, rows: UInt16)? = nil,
        hasRemoteClient: @escaping () -> Bool = { false },
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
        self.hasRemoteClient = hasRemoteClient
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

    /// Forward bytes to the zmx PTY.
    ///
    /// - Parameter claimEngagement: When `true` (default), this write
    ///   counts as user input under IOS-12.1: the silent gate flips to
    ///   `.engaged` AFTER the write succeeds, flushing any queued
    ///   viewport size to the PTY. Programmatic call sites (initial
    ///   `extraInitialInput`, `typeText` from `splitPane`/`send-pane`,
    ///   the idle-agent nudge writer) pass `false` so they don't
    ///   silently claim a user-input contract they don't represent.
    func write(_ data: Data, claimEngagement: Bool = true) throws {
        guard !data.isEmpty else { return }

        let currentSession = try activeSession()
        try currentSession.write(data)

        // IOS-12.1: flip the gate only AFTER a successful write — a write
        // that throws `notStarted` or fails inside the session shall not
        // disengage the silent gate.
        if claimEngagement {
            markUserInput()
        }
    }

    /// Runs `body` with the programmatic-input flag raised. Any bytes that
    /// libghostty emits through `receiveBufferCallback` during `body` are
    /// treated as automation (synthesized keys, programmatic clipboard
    /// pastes, etc.) — they reach the PTY but do NOT flip IOS-12.1's
    /// silent gate. Used by `SurfaceHandle.pressReturn(claimEngagement:
    /// false)` so the Return synthesized for `graftty pane send … --enter`
    /// matches the policy that the companion `typeText` write already
    /// follows. Reentrant via a depth counter.
    ///
    /// Named `…Scope` (not `withProgrammaticInput`) so the protocol
    /// witness in `SurfaceHandle.swift` can forward to it without
    /// colliding with its own name.
    func withProgrammaticInputScope<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        programmaticInputDepth += 1
        lock.unlock()
        defer {
            lock.lock()
            programmaticInputDepth -= 1
            lock.unlock()
        }
        return try body()
    }

    /// Binds the surface-sync closures. To be called by SurfaceHandle after
    /// ghostty_surface_new succeeds and before start(surface:). The
    /// closures must be safe to call from the backend's lock (they issue
    /// a single libghostty query / refresh request — no re-entrancy into
    /// the backend), and they are invoked from whatever thread triggers a
    /// flush — libghostty's IO thread (`write` via receiveBufferCallback),
    /// IPC threads, or AppKit's main thread (`markLayoutSettled`) — NOT
    /// only the main thread. The flush paths never run after `close()`
    /// (lifecycle-gated), which orders before ghostty_surface_free in
    /// SurfaceHandle.deinit, so a bound surface pointer cannot dangle.
    func bindSurfaceSync(
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.currentGridSize = currentGridSize
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    /// TERM-11.1: the owning NSView received its first nonzero frame.
    /// One-shot: if the pane is still silent and no remote client is
    /// attached, sync the PTY to the current grid so zmx formats output
    /// for the dims libghostty is actually rendering.
    func markLayoutSettled() {
        lock.lock()
        defer { lock.unlock() }
        guard !layoutSettled else { return }
        layoutSettled = true
        guard case .silent = attachState, !hasRemoteClient() else { return }
        flushSizeToPtyLocked(refresh: false)
    }

    /// TERM-11.4: the last remote client detached from this session. A
    /// still-silent pane syncs the PTY to the current grid immediately —
    /// there is no longer anyone whose width we must preserve. Re-checks
    /// `hasRemoteClient` because the registry fires its observer outside
    /// its lock: another client may have re-attached by the time this runs.
    func remoteClientsDidDetach() {
        lock.lock()
        defer { lock.unlock() }
        guard case .silent = attachState, layoutSettled, !hasRemoteClient() else { return }
        flushSizeToPtyLocked(refresh: true)
    }

    /// Snapshot of `programmaticInputDepth > 0` used by
    /// `receiveBufferCallback` to decide whether the imminent `write`
    /// should engage the gate. Lock-protected so it stays coherent with
    /// `withProgrammaticInput`'s increment/decrement on the same lock.
    fileprivate var isProgrammaticInputActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return programmaticInputDepth > 0
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
        // No `attachState` / `lastSilentResize` reset here: `.closed` is
        // terminal and `start()` rejects it (`Error.closed`), so there
        // is no "next attach" on this instance. Per-process reattach is
        // handled by constructing a fresh `HostManagedZmxBackend`.
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
        if case .silent = attachState {
            // TERM-11.2 / IOS-12.1: withhold while layout hasn't settled
            // (pre-layout libghostty noise) or while a remote client is
            // attached (the Mac must not steal the session width without
            // user engagement). Otherwise forward without engaging.
            if !layoutSettled || hasRemoteClient() {
                lastSilentResize = PendingResize(cols: cols, rows: rows)
                lock.unlock()
                return
            }
            lastSilentResize = nil
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
    /// attach. The first call syncs the PTY to the current grid (TERM-11.3)
    /// so any dims withheld under IOS-12.1 land before post-engagement
    /// bytes. IOS-12.1.
    ///
    /// The lock is held across the flush `resize` call so any concurrent
    /// `write` on another thread cannot ship bytes to the PTY before the
    /// flush lands — invariant: post-engagement bytes always see the
    /// post-flush PTY dims.
    private func markUserInput() {
        lock.lock()
        defer { lock.unlock() }

        guard case .silent = attachState else { return }
        attachState = .engaged
        flushSizeToPtyLocked(refresh: true)
    }

    /// Shared sync tail for markUserInput / markLayoutSettled /
    /// remoteClientsDidDetach. Caller holds `lock`. Resolves the sync
    /// target — the live grid when a provider is bound, else the last
    /// withheld viewport size — and ships it to the PTY (or queues it
    /// when the session is still starting). `resize` does take the
    /// session's ioLock, but ioLock holders never take the backend lock,
    /// so the backend→ioLock order is acyclic; the ioctl itself is
    /// milliseconds at most, keeping the contention window bounded.
    private func flushSizeToPtyLocked(refresh: Bool) {
        // Bail before touching the closures on a closed backend: close()
        // happens-before ghostty_surface_free, so this lifecycle gate is
        // what keeps a bound `currentGridSize` surface pointer from being
        // dereferenced after the surface is gone.
        if case .closed = lifecycle { return }
        let queued = lastSilentResize
        lastSilentResize = nil
        let target = currentGridSize() ?? queued.map { (cols: $0.cols, rows: $0.rows) }
        guard let target else { return }
        switch lifecycle {
        case .running:
            try? session?.resize(cols: target.cols, rows: target.rows)
            if refresh {
                requestRefresh()
            }
        case .idle, .starting:
            pendingResize = PendingResize(cols: target.cols, rows: target.rows)
        case .closed:
            break
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
