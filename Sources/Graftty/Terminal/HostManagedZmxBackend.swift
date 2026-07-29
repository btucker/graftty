import Foundation
import GhosttyKit
import GrafttyKit
import GrafttyProtocol
import os

protocol HostManagedZmxSession: AnyObject {
    func start() throws
    func write(_ data: Data) throws
    func resize(cols: UInt16, rows: UInt16) throws
    func resize(windowSize: PtyProcess.WindowSize) throws
    func close()
}

extension HostManagedZmxSession {
    func resize(windowSize: PtyProcess.WindowSize) throws {
        try resize(cols: windowSize.cols, rows: windowSize.rows)
    }
}

extension NativePtySession: HostManagedZmxSession {}

/// Render-desync diagnostic trail (TERM-11.x): every PTY-resize decision
/// the host-managed backend makes, with the inputs that drove it.
/// `log stream --predicate 'subsystem == "com.graftty.app" AND
/// category == "resize-trace"'`.
enum ResizeTrace {
    static let log = Logger(subsystem: "com.graftty.app", category: "resize-trace")
}

struct HostManagedZmxOwnership {
    let clientID: DisplayClientID
    let kind: DisplayClientKind

    private let snapshotImpl: (DisplayGrid) -> DisplayOwnershipSnapshot
    private let attachImpl: (Bool, DisplayGrid) -> DisplayOwnershipSnapshot
    private let claimImpl: (DisplayGrid) -> SessionDisplayOwnershipClaimResult
    private let claimIfOwnerlessOrCurrentImpl: (DisplayGrid) -> SessionDisplayOwnershipClaimResult
    private let ownerResizeImpl: (UInt64, DisplayGrid) -> SessionDisplayOwnershipResizeResult
    private let releaseImpl: (DisplayGrid) -> DisplayOwnershipSnapshot
    private let restoreFailedClaimImpl: (UInt64, DisplayOwnershipSnapshot, DisplayGrid) -> DisplayOwnershipSnapshot
    private let detachImpl: (DisplayGrid) -> DisplayOwnershipSnapshot

    init(
        clientID: DisplayClientID,
        kind: DisplayClientKind = .mac,
        snapshot: @escaping (DisplayGrid) -> DisplayOwnershipSnapshot,
        attach: @escaping (Bool, DisplayGrid) -> DisplayOwnershipSnapshot,
        claim: @escaping (DisplayGrid) -> SessionDisplayOwnershipClaimResult,
        claimIfOwnerlessOrCurrent: @escaping (DisplayGrid) -> SessionDisplayOwnershipClaimResult,
        ownerResize: @escaping (UInt64, DisplayGrid) -> SessionDisplayOwnershipResizeResult,
        release: @escaping (DisplayGrid) -> DisplayOwnershipSnapshot,
        restoreFailedClaim: @escaping (UInt64, DisplayOwnershipSnapshot, DisplayGrid) -> DisplayOwnershipSnapshot,
        detach: @escaping (DisplayGrid) -> DisplayOwnershipSnapshot
    ) {
        self.clientID = clientID
        self.kind = kind
        self.snapshotImpl = snapshot
        self.attachImpl = attach
        self.claimImpl = claim
        self.claimIfOwnerlessOrCurrentImpl = claimIfOwnerlessOrCurrent
        self.ownerResizeImpl = ownerResize
        self.releaseImpl = release
        self.restoreFailedClaimImpl = restoreFailedClaim
        self.detachImpl = detach
    }

    init(
        store: SessionDisplayOwnershipStore,
        sessionName: String,
        clientID: DisplayClientID,
        kind: DisplayClientKind = .mac
    ) {
        self.init(
            clientID: clientID,
            kind: kind,
            snapshot: { fallbackGrid in
                store.snapshot(sessionName: sessionName, fallbackGrid: fallbackGrid)
            },
            attach: { visible, grid in
                store.attachClient(
                    sessionName: sessionName,
                    clientID: clientID,
                    kind: kind,
                    role: .interactive,
                    visible: visible,
                    grid: grid
                )
            },
            claim: { grid in
                store.claimOwner(
                    sessionName: sessionName,
                    clientID: clientID,
                    kind: kind,
                    grid: grid
                )
            },
            claimIfOwnerlessOrCurrent: { grid in
                store.claimOwnerIfOwnerlessOrCurrent(
                    sessionName: sessionName,
                    clientID: clientID,
                    kind: kind,
                    grid: grid
                )
            },
            ownerResize: { epoch, grid in
                store.ownerResize(
                    sessionName: sessionName,
                    clientID: clientID,
                    epoch: epoch,
                    grid: grid
                )
            },
            release: { fallbackGrid in
                store.releaseOwner(
                    sessionName: sessionName,
                    clientID: clientID,
                    fallbackGrid: fallbackGrid
                )
            },
            restoreFailedClaim: { failedEpoch, previousSnapshot, fallbackGrid in
                store.restoreOwnerAfterFailedClaim(
                    sessionName: sessionName,
                    failedClientID: clientID,
                    failedKind: kind,
                    failedEpoch: failedEpoch,
                    previousOwnerClientID: previousSnapshot.ownerClientID,
                    previousOwnerKind: previousSnapshot.ownerKind,
                    previousGrid: previousSnapshot.grid,
                    fallbackGrid: fallbackGrid
                )
            },
            detach: { fallbackGrid in
                store.detachClient(
                    sessionName: sessionName,
                    clientID: clientID,
                    fallbackGrid: fallbackGrid
                )
            }
        )
    }

    func snapshot(fallbackGrid: DisplayGrid) -> DisplayOwnershipSnapshot {
        snapshotImpl(fallbackGrid)
    }

    func attach(visible: Bool, grid: DisplayGrid) -> DisplayOwnershipSnapshot {
        attachImpl(visible, grid)
    }

    func claim(grid: DisplayGrid) -> SessionDisplayOwnershipClaimResult {
        claimImpl(grid)
    }

    func claimIfOwnerlessOrCurrent(grid: DisplayGrid) -> SessionDisplayOwnershipClaimResult {
        claimIfOwnerlessOrCurrentImpl(grid)
    }

    func ownerResize(epoch: UInt64, grid: DisplayGrid) -> SessionDisplayOwnershipResizeResult {
        ownerResizeImpl(epoch, grid)
    }

    func release(fallbackGrid: DisplayGrid) -> DisplayOwnershipSnapshot {
        releaseImpl(fallbackGrid)
    }

    func restoreFailedClaim(
        failedEpoch: UInt64,
        previousSnapshot: DisplayOwnershipSnapshot,
        fallbackGrid: DisplayGrid
    ) -> DisplayOwnershipSnapshot {
        restoreFailedClaimImpl(failedEpoch, previousSnapshot, fallbackGrid)
    }

    func detach(fallbackGrid: DisplayGrid) -> DisplayOwnershipSnapshot {
        detachImpl(fallbackGrid)
    }
}

final class HostManagedZmxBackend {
    private static var trace: Logger { ResizeTrace.log }

    typealias SessionFactory = (
        _ surface: ghostty_surface_t,
        _ spawnConfiguration: ZmxSpawnConfiguration,
        _ initialSize: PtyProcess.WindowSize?
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

    private typealias PendingResize = PtyProcess.WindowSize

    private struct AuthorizedResize {
        let resize: PendingResize
        let epoch: UInt64
    }

    /// Schedules `fire` after `delay` seconds and returns a cancel
    /// closure. Seam for TERM-11.9's trailing-edge resize coalescing —
    /// production uses GCD (`defaultResizeCoalescingScheduler`); tests
    /// inject a manual recorder for deterministic window expiry.
    typealias ResizeCoalescingScheduler = (
        _ delay: TimeInterval,
        _ fire: @escaping () -> Void
    ) -> (() -> Void)

    static let defaultResizeCoalescingScheduler: ResizeCoalescingScheduler = { delay, fire in
        let item = DispatchWorkItem(block: fire)
        DispatchQueue.global(qos: .userInteractive)
            .asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }

    /// TERM-11.9 quiet window. A divider drag emits viewport callbacks
    /// every frame (~8ms); 75ms collapses a drag into ≲13 SIGWINCHes/s
    /// through zmx instead of ~120, while a lone resize still lands
    /// instantly on the leading edge.
    private static let resizeCoalesceDelay: TimeInterval = 0.075

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr, len > 0 else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        let data = Data(bytes: ptr, count: len)
        // Host-managed input that arrives before the PTY session is running is
        // intentionally dropped. SurfaceHandle sends explicit extraInitialInput
        // with write(_:) after start succeeds.
        //
        // The user/programmatic scope flag is preserved for callers that
        // still annotate libghostty-emitted bytes, but display ownership
        // alone decides whether PTY-bound bytes are forwarded.
        try? backend.write(data, claimEngagement: backend.emittedBytesClaimEngagement)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        backend.receiveResize(
            PtyProcess.WindowSize(
                cols: cols,
                rows: rows,
                xpixel: UInt16(clamping: widthPx),
                ypixel: UInt16(clamping: heightPx)
            )
        )
    }

    private let spawnConfiguration: ZmxSpawnConfiguration
    private let initialSize: PtyProcess.WindowSize?
    private let scheduleCoalescedResize: ResizeCoalescingScheduler
    private let sessionFactory: SessionFactory
    private let lock = NSLock()

    private var lifecycle: Lifecycle = .idle
    private var session: HostManagedZmxSession?
    private var pendingResize: PendingResize?

    /// TERM-11.12: writes arriving before the session starts (e.g.
    /// `pane add --command` typing before the pane's first layout under
    /// TERM-11.10's deferred attach). Delivered in order by `start()`,
    /// after any queued resize, and only when this attachment is allowed
    /// to write by the display ownership gate.
    private var pendingWrites: [(data: Data, claimEngagement: Bool)] = []
    private var lastWithheldResize: PendingResize?
    private var userdataPointer: UnsafeMutableRawPointer!

    /// TERM-11.9 coalescing state. `coalesceCancel != nil` means the
    /// quiet window is open: forwarded resizes opened it, and any resize
    /// arriving while it's open parks in `pendingCoalescedResize`
    /// (latest wins) until the window expires. `lastForwardedResize`
    /// suppresses redundant trailing SIGWINCHes.
    ///
    /// Dual-purpose, and the second role matters for TERM-11.15: it is
    /// advanced ONLY after a confirmed-successful `resize`, and CLEARED
    /// (set to nil) on a swallowed `resize` failure. A nil therefore means
    /// "the PTY's adopted size is unknown / not what we last attempted" —
    /// it is the failure sentinel that keeps the coalescer's `pending ==
    /// lastForwardedResize` dedup from suppressing a re-forward of a size
    /// the PTY never actually adopted.
    private var coalesceCancel: (() -> Void)?
    private var pendingCoalescedResize: PendingResize?
    private var lastForwardedResize: PendingResize?
    private var latestPixelSize: (xpixel: UInt16, ypixel: UInt16)

    /// Reentrant counter tracking active `withProgrammaticInput` scopes.
    /// While > 0, `receiveBufferCallback` treats the inbound bytes as
    /// automation and passes `claimEngagement: false` to `write`. The
    /// flag no longer grants resize/input authority; ownership does.
    private var programmaticInputDepth: Int = 0

    /// Reentrant counter tracking active `withUserInputScope` bodies.
    /// TERM-11.8 compatibility scope for real key dispatches. Bytes
    /// emitted inside this scope are still tagged as user-originated for
    /// legacy call sites, but they do not claim resize/input authority.
    private var userInputDepth: Int = 0

    /// Task 4 ownership gate. When nil, this backend behaves like a
    /// standalone host-managed surface and forwards local writes/resizes.
    private let ownership: HostManagedZmxOwnership?
    private var ownershipSnapshot: DisplayOwnershipSnapshot?
    private var attachedToOwnership = false

    /// The surface-sync closures are bound by SurfaceHandle after
    /// ghostty_surface_new succeeds, before start(surface:).
    private var currentWindowSize: () -> PendingResize? = { nil }
    /// Grid-only compatibility seam retained for focused backend tests.
    /// Production SurfaceHandle binds `currentWindowSize`, keeping cell
    /// and pixel dimensions in one atomic libghostty snapshot.
    private var currentGridSize: () -> (cols: UInt16, rows: UInt16)? = { nil }
    private var requestRefresh: () -> Void = {}

    /// Flips true (once) when the owning NSView first receives a nonzero
    /// frame. Pre-settle viewport callbacks are never forwarded; they are
    /// libghostty pre-layout noise (the original PR #201 bug; TERM-11.7).
    private var layoutSettled = false

    init(
        spawnConfiguration: ZmxSpawnConfiguration,
        initialSize: PtyProcess.WindowSize? = nil,
        hasRemoteClient: @escaping () -> Bool = { false },
        ownership: HostManagedZmxOwnership? = nil,
        scheduleCoalescedResize: @escaping ResizeCoalescingScheduler = HostManagedZmxBackend.defaultResizeCoalescingScheduler,
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
        self.latestPixelSize = (
            xpixel: initialSize?.xpixel ?? 0,
            ypixel: initialSize?.ypixel ?? 0
        )
        _ = hasRemoteClient
        self.ownership = ownership
        self.scheduleCoalescedResize = scheduleCoalescedResize
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
            lastWithheldResize = nil
            lifecycle = .starting
            lock.unlock()
        case .starting, .running:
            lock.unlock()
            throw Error.alreadyStarted
        case .closed:
            lock.unlock()
            throw Error.closed
        }

        // TERM-11.10: spawn at the live window size when the surface-sync
        // provider is bound (it is, before any deferred start) — the
        // construction-time initialSize is the eviction-cache fallback
        // and can be stale relative to the settled layout.
        lock.lock()
        let windowQuery = currentWindowSize
        let gridQuery = currentGridSize
        let initialPixelSize = latestPixelSize
        lock.unlock()
        let spawnSize = windowQuery() ?? gridQuery().map {
            PtyProcess.WindowSize(
                cols: $0.cols,
                rows: $0.rows,
                xpixel: initialPixelSize.xpixel,
                ypixel: initialPixelSize.ypixel
            )
        } ?? initialSize
        attachToOwnershipIfNeeded(
            grid: spawnSize.flatMap { Self.displayGrid(from: $0) } ?? .daemonFallback
        )
        let newSession = sessionFactory(surface, spawnConfiguration, spawnSize)

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
                    guard let authorized = authorizeOwnerResizeLocked(resize) else {
                        lock.unlock()
                        continue
                    }
                    lock.unlock()
                    if (try? newSession.resize(windowSize: resize)) == nil {
                        lock.lock()
                        if lastForwardedResize == resize { lastForwardedResize = nil }
                        lock.unlock()
                    } else {
                        lock.lock()
                        let result = commitOwnerResizeLocked(authorized)
                        lock.unlock()
                        if !result.accepted, let snapshot = result.snapshot {
                            repairSession(newSession, to: snapshot)
                        }
                    }
                    continue
                }
                // TERM-11.12: drain queued pre-start writes (after any
                // queued resize, before flipping `.running` so a racing
                // direct write can't jump ahead of the queue).
                if !pendingWrites.isEmpty {
                    let queued = pendingWrites
                    pendingWrites = []
                    lock.unlock()
                    for entry in queued {
                        if writeAllowed() {
                            try? newSession.write(entry.data)
                        }
                    }
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
    /// - Parameter claimEngagement: Legacy annotation from the previous
    ///   silent-gate model. It is retained so existing call sites can keep
    ///   distinguishing programmatic bytes from real key dispatches, but
    ///   display ownership is now the only write authority.
    func write(_ data: Data, claimEngagement: Bool = true) throws {
        guard !data.isEmpty else { return }

        // TERM-11.12: queue instead of throwing while the session hasn't
        // started — under the deferred attach (TERM-11.10), `pane add
        // --command` types before the pane's first layout, and dropping
        // those bytes loses the command. `start()` drains the queue.
        lock.lock()
        switch lifecycle {
        case .closed:
            lock.unlock()
            throw Error.closed
        case .idle, .starting:
            pendingWrites.append((data, claimEngagement))
            lock.unlock()
            Self.trace.notice("write \(self.spawnConfiguration.sessionName, privacy: .public) \(data.count) bytes QUEUED (pre-start)")
            return
        case .running:
            lock.unlock()
        }

        // One snapshot on the steady-state owner path; re-check only after an
        // actual takeControl() flips ownership. `writeAllowed()` takes a store
        // snapshot under lock, so calling it twice unconditionally would double
        // that cost on every byte chunk libghostty emits.
        var allowed = writeAllowed()
        if !allowed, claimEngagement {
            _ = takeControl()
            allowed = writeAllowed()
        }
        guard allowed else {
            Self.trace.notice("write \(self.spawnConfiguration.sessionName, privacy: .public) \(data.count) bytes BLOCKED (follower)")
            return
        }
        let currentSession = try activeSession()
        try currentSession.write(data)
    }

    /// Runs `body` with the programmatic-input flag raised. Any bytes that
    /// libghostty emits through `receiveBufferCallback` during `body` are
    /// treated as automation (synthesized keys, programmatic clipboard
    /// pastes, etc.). Ownership still decides whether those bytes reach
    /// the PTY. Reentrant via a depth counter.
    ///
    /// Named `…Scope` (not `withProgrammaticInput`) so the protocol
    /// witness in `SurfaceHandle.swift` can forward to it without
    /// colliding with its own name.
    func withProgrammaticInputScope<T>(_ body: () throws -> T) rethrows -> T {
        try withDepthScope(\.programmaticInputDepth, body)
    }

    /// Shared lock/increment/decrement shape for the two reentrant input
    /// scopes (`withProgrammaticInputScope` / `withUserInputScope`).
    private func withDepthScope<T>(
        _ depth: ReferenceWritableKeyPath<HostManagedZmxBackend, Int>,
        _ body: () throws -> T
    ) rethrows -> T {
        lock.lock()
        self[keyPath: depth] += 1
        lock.unlock()
        defer {
            lock.lock()
            self[keyPath: depth] -= 1
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
        currentWindowSize: @escaping () -> PtyProcess.WindowSize?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.currentWindowSize = currentWindowSize
        self.currentGridSize = { nil }
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    /// Grid-only compatibility seam for backend-focused tests. Production
    /// callers must bind the full window-size overload above so a live cell
    /// grid is never paired with stale pixel dimensions.
    func bindSurfaceSync(
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.currentWindowSize = { nil }
        self.currentGridSize = currentGridSize
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    /// TERM-11.1 / TERM-11.6: the owning NSView received its first
    /// nonzero frame. One-shot: owners sync the PTY to the current grid
    /// through the ownership store; followers only settle local
    /// presentation. Pre-settle callbacks remain withheld because
    /// libghostty can report placeholder grids before AppKit has laid out.
    func markLayoutSettled() {
        lock.lock()
        defer { lock.unlock() }
        guard !layoutSettled else { return }
        layoutSettled = true
        // Refresh deliberately dropped: setFrameSize already issued one
        // on this same frame event two statements before notifying us.
        _ = flushSizeToPtyLocked(reason: "layoutSettled")
    }

    /// TERM-11.4: the last remote client detached from this session. A
    /// previous native sizing gate used this as a resize authority signal.
    /// Ownership is now explicit, so remote attachment accounting must not
    /// resize the PTY or claim display authority.
    func remoteClientsDidDetach() {
        Self.trace.notice("remoteClientsDidDetach \(self.spawnConfiguration.sessionName, privacy: .public) NO-SYNC ownership-gated")
    }

    @discardableResult
    func takeControl() -> Bool {
        guard let ownership else { return false }

        lock.lock()
        guard attachedToOwnership else {
            lock.unlock()
            return false
        }
        let liveWindow = currentWindowSize()
        let legacyGrid = liveWindow == nil ? currentGridSize() : nil
        let target = liveWindow ?? legacyGrid.map {
            PendingResize(
                cols: $0.cols,
                rows: $0.rows,
                xpixel: latestPixelSize.xpixel,
                ypixel: latestPixelSize.ypixel
            )
        } ?? lastWithheldResize
        guard let target, let grid = Self.displayGrid(from: target) else {
            lock.unlock()
            return false
        }
        guard case .running = lifecycle, let currentSession = session else {
            lock.unlock()
            return false
        }
        let previousSnapshot = ownership.snapshot(fallbackGrid: fallbackDisplayGridLocked())
        let result = ownership.claim(grid: previousSnapshot.grid)
        ownershipSnapshot = result.snapshot
        guard result.accepted else {
            lock.unlock()
            return false
        }
        let resize = PendingResize(
            cols: grid.cols,
            rows: grid.rows,
            xpixel: target.xpixel,
            ypixel: target.ypixel
        )
        pendingCoalescedResize = nil
        lastForwardedResize = resize
        let refresh = requestRefresh
        lock.unlock()

        if (try? currentSession.resize(windowSize: resize)) == nil {
            lock.lock()
            if lastForwardedResize == resize { lastForwardedResize = nil }
            let restoredSnapshot = ownership.restoreFailedClaim(
                failedEpoch: result.snapshot.epoch,
                previousSnapshot: previousSnapshot,
                fallbackGrid: fallbackDisplayGridLocked()
            )
            ownershipSnapshot = restoredSnapshot
            lock.unlock()
            return false
        }
        let resizeResult = ownership.ownerResize(epoch: result.snapshot.epoch, grid: grid)
        lock.lock()
        ownershipSnapshot = resizeResult.snapshot
        if !resizeResult.accepted {
            if lastForwardedResize == resize { lastForwardedResize = nil }
        }
        lock.unlock()
        guard resizeResult.accepted else {
            repairSession(currentSession, to: resizeResult.snapshot)
            return false
        }
        refresh()
        return true
    }

    /// TERM-11.13 / TERM-11.17: a pane entered the visible set. While it was
    /// occluded the window's grid may have drifted to a row/col count the PTY
    /// never received: libghostty emits a viewport callback only on a grid
    /// *delta*, and an occluded surface shown at a size it already held
    /// produces none, so the PTY keeps its stale latched dims and the
    /// session's TUI renders off-anchor (the "off by N lines" desync) until a
    /// real resize forces a SIGWINCH — which is exactly why a manual vertical
    /// resize fixes it. This also applies to first visibility after an
    /// explicit background start: the session is already running, but no
    /// layout callback has settled the never-mounted view.
    ///
    /// We forward the live grid unconditionally rather than short-circuiting
    /// when it "matches" `lastForwardedResize`. That record is an optimistic
    /// proxy set BEFORE the resize call, with errors swallowed by `try?`, so
    /// it can lie about what the PTY actually adopted (a failed ioctl leaves it
    /// stale). Trusting it would hide a real Mac↔daemon size divergence until
    /// the user manually resizes. A same-size `TIOCSWINSZ` is a kernel no-op
    /// (no SIGWINCH emitted), so forwarding on every show costs one syscall
    /// and never churns the TUI, while correctly recovering from any prior
    /// failed forward. A running background session deliberately bypasses the
    /// viewport callback's pre-layout gate here: visibility is an explicit
    /// authoritative lifecycle event, not unsolicited placeholder noise.
    /// Ordinary deferred panes are still idle and therefore no-op; followers
    /// still no-op when the ownership check rejects the resize.
    func resyncVisibleGrid() {
        lock.lock()
        // No `currentGridSize() != nil` pre-check here: `flushSizeToPtyLocked`
        // re-reads the grid and handles a nil target (NO-TARGET) itself, so a
        // pre-check would just query libghostty twice under the lock.
        guard case .running = lifecycle else {
            lock.unlock()
            return
        }
        // Forward the live grid unconditionally. We deliberately do NOT
        // short-circuit when it "matches" `lastForwardedResize`: that record is
        // an optimistic proxy (set before the resize, with the failure swallowed
        // by `try?`), so trusting it can hide a real Mac/daemon size divergence
        // and leave the TUI rendering off-anchor until a manual resize. A
        // same-size `TIOCSWINSZ` is a kernel no-op (no SIGWINCH), so forwarding on
        // every show costs one syscall and never churns the TUI, while a forward
        // after a previously-failed/ignored resize corrects the divergence.
        let refresh = flushSizeToPtyLocked(reason: "showResync")
        lock.unlock()
        refresh?()
    }

    /// Single-lock snapshot of whether bytes arriving via
    /// `receiveBufferCallback` were emitted during a real user key
    /// dispatch. This is a compatibility annotation; it does not decide
    /// ownership.
    fileprivate var emittedBytesClaimEngagement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userInputDepth > 0 && programmaticInputDepth == 0
    }

    /// Runs `body` with the user-input flag raised. The view wraps real
    /// key-event dispatch (`ghostty_surface_key` from `keyDown` / `keyUp`)
    /// in this scope. Ownership still decides whether resulting bytes
    /// reach the PTY. TERM-11.8. Reentrant via a depth counter.
    func withUserInputScope<T>(_ body: () throws -> T) rethrows -> T {
        try withDepthScope(\.userInputDepth, body)
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
        pendingWrites = []
        // TERM-11.9: cancel an in-flight quiet window; a fire that races
        // this cancel is also lifecycle-gated in coalesceWindowExpired.
        let cancelCoalesce = coalesceCancel
        coalesceCancel = nil
        pendingCoalescedResize = nil
        let shouldDetach = attachedToOwnership
        attachedToOwnership = false
        let detachFallback = fallbackDisplayGridLocked()
        lock.unlock()

        if shouldDetach, let ownership {
            _ = ownership.detach(fallbackGrid: detachFallback)
        }
        cancelCoalesce?()
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

    private func receiveResize(_ resize: PendingResize) {
        let currentSession: HostManagedZmxSession?

        lock.lock()
        latestPixelSize = (xpixel: resize.xpixel, ypixel: resize.ypixel)
        // TERM-11.7: withhold while layout hasn't settled. These
        // callbacks are pre-layout placeholder noise and must never reach
        // the PTY, regardless of display ownership.
        if !layoutSettled {
            lastWithheldResize = resize
            lock.unlock()
            Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(resize.cols)x\(resize.rows) pixels=\(resize.xpixel)x\(resize.ypixel) WITHHELD layout")
            return
        }
        guard let authorized = authorizeOwnerResizeLocked(resize) else {
            lock.unlock()
            Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(resize.cols)x\(resize.rows) pixels=\(resize.xpixel)x\(resize.ypixel) BLOCKED follower-or-stale")
            return
        }
        // Forwarding live dims supersedes anything withheld earlier;
        // clearing keeps later flushes from resurrecting a stale
        // pre-layout size when no grid provider is bound.
        lastWithheldResize = nil
        switch lifecycle {
        case .idle, .starting:
            pendingResize = resize
            currentSession = nil
        case .running:
            // TERM-11.9: while the quiet window is open (a drag in
            // progress), park the latest size instead of forwarding —
            // the window's trailing fire delivers it.
            if coalesceCancel != nil {
                pendingCoalescedResize = resize
                lock.unlock()
                Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(resize.cols)x\(resize.rows) pixels=\(resize.xpixel)x\(resize.ypixel) COALESCED")
                return
            }
            lastForwardedResize = resize
            openCoalesceWindowLocked()
            currentSession = session
        case .closed:
            currentSession = nil
        }
        lock.unlock()

        Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(resize.cols)x\(resize.rows) pixels=\(resize.xpixel)x\(resize.ypixel) \(currentSession != nil ? "FORWARDED" : "QUEUED", privacy: .public)")
        if let s = currentSession, (try? s.resize(windowSize: resize)) == nil {
            // Forward failed — don't let the optimistic record lie about what the
            // PTY adopted. Clear only if it's still ours (a newer forward may have
            // landed between unlock and now).
            lock.lock()
            if lastForwardedResize == resize {
                lastForwardedResize = nil
            }
            lock.unlock()
        } else if currentSession != nil {
            lock.lock()
            let result = commitOwnerResizeLocked(authorized)
            if !result.accepted, lastForwardedResize == resize {
                lastForwardedResize = nil
            }
            lock.unlock()
            if !result.accepted, let snapshot = result.snapshot, let currentSession {
                repairSession(currentSession, to: snapshot)
            }
        }
    }

    /// Opens the TERM-11.9 quiet window. Caller holds `lock`. The
    /// scheduler only enqueues the trailing fire (no synchronous
    /// callback, no backend re-entry), so invoking it under the lock is
    /// safe.
    private func openCoalesceWindowLocked() {
        coalesceCancel = scheduleCoalescedResize(Self.resizeCoalesceDelay) { [weak self] in
            self?.coalesceWindowExpired()
        }
    }

    /// Trailing edge of the TERM-11.9 quiet window: forward the latest
    /// parked size (if it still differs from what the PTY last saw) and
    /// reopen the window so a sustained drag keeps throttling.
    private func coalesceWindowExpired() {
        lock.lock()
        coalesceCancel = nil
        guard case .running = lifecycle,
              let pending = pendingCoalescedResize else {
            pendingCoalescedResize = nil
            lock.unlock()
            return
        }
        pendingCoalescedResize = nil
        guard let authorized = authorizeOwnerResizeLocked(pending) else {
            lock.unlock()
            Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(pending.cols)x\(pending.rows) TRAILING-BLOCKED")
            return
        }
        if pending == lastForwardedResize {
            lock.unlock()
            return
        }
        lastForwardedResize = pending
        openCoalesceWindowLocked()
        let currentSession = session
        lock.unlock()

        Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(pending.cols)x\(pending.rows) TRAILING")
        if let s = currentSession, (try? s.resize(windowSize: pending)) == nil {
            lock.lock()
            if let lf = lastForwardedResize, lf == pending { lastForwardedResize = nil }
            lock.unlock()
        } else if currentSession != nil {
            lock.lock()
            let result = commitOwnerResizeLocked(authorized)
            if !result.accepted, lastForwardedResize == pending {
                lastForwardedResize = nil
            }
            lock.unlock()
            if !result.accepted, let snapshot = result.snapshot, let currentSession {
                repairSession(currentSession, to: snapshot)
            }
        }
    }

    /// Shared sync tail for markLayoutSettled / resyncVisibleGrid /
    /// takeControl. Caller holds `lock`.
    /// Resolves the sync target — the live window when a provider is bound,
    /// else the last withheld viewport size — and ships it to the PTY (or
    /// queues it when the session is still starting). `resize` does take
    /// the session's ioLock, but ioLock holders never take the backend
    /// lock, so the backend→ioLock order is acyclic; the ioctl itself is
    /// milliseconds at most, keeping the contention window bounded.
    ///
    /// Returns the bound `requestRefresh` closure when a running-session
    /// resize landed (captured under `lock`), nil otherwise. The caller
    /// invokes it AFTER releasing `lock` — the refresh re-enters
    /// libghostty, and issuing it lock-free keeps the backend-lock ↔
    /// libghostty-internal-lock pair acyclic even when this path runs
    /// inside a libghostty callback.
    private func flushSizeToPtyLocked(reason: StaticString) -> (() -> Void)? {
        // Bail before touching the closures on a closed backend: close()
        // happens-before ghostty_surface_free, so this lifecycle gate is
        // what keeps a bound surface-size query from being
        // dereferenced after the surface is gone.
        if case .closed = lifecycle { return nil }
        let queued = lastWithheldResize
        lastWithheldResize = nil
        let liveWindow = currentWindowSize()
        let legacyGrid = liveWindow == nil ? currentGridSize() : nil
        let pending = liveWindow ?? legacyGrid.map {
            PendingResize(
                cols: $0.cols,
                rows: $0.rows,
                xpixel: latestPixelSize.xpixel,
                ypixel: latestPixelSize.ypixel
            )
        } ?? queued
        guard let pending else {
            Self.trace.notice("flush(\(reason, privacy: .public)) \(self.spawnConfiguration.sessionName, privacy: .public) NO-TARGET")
            return nil
        }
        guard let authorized = authorizeOwnerResizeLocked(pending) else {
            Self.trace.notice("flush(\(reason, privacy: .public)) \(self.spawnConfiguration.sessionName, privacy: .public) BLOCKED follower-or-stale")
            return nil
        }
        Self.trace.notice("flush(\(reason, privacy: .public)) \(self.spawnConfiguration.sessionName, privacy: .public) -> \(pending.cols)x\(pending.rows) fromWindow=\(liveWindow != nil) fromLegacyGrid=\(legacyGrid != nil) queued=\(queued.map { "\($0.cols)x\($0.rows)" } ?? "nil", privacy: .public)")
        switch lifecycle {
        case .running:
            // TERM-11.9: the flush supersedes any mid-drag size parked
            // in the quiet window — a stale coalesced resize must not
            // land after this authoritative sync.
            pendingCoalescedResize = nil
            if (try? session?.resize(windowSize: pending)) != nil {
                let result = commitOwnerResizeLocked(authorized)
                if result.accepted {
                    lastForwardedResize = pending
                } else {
                    lastForwardedResize = nil
                    if let snapshot = result.snapshot {
                        try? session?.resize(
                            windowSize: Self.gridOnlyWindowSize(snapshot.grid)
                        )
                    }
                    return nil
                }
            } else {
                lastForwardedResize = nil
            }
            return requestRefresh
        case .idle, .starting:
            pendingResize = pending
            return nil
        case .closed:
            return nil
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

    private func attachToOwnershipIfNeeded(grid: DisplayGrid) {
        guard let ownership else { return }
        lock.lock()
        guard !attachedToOwnership else {
            lock.unlock()
            return
        }
        attachedToOwnership = true
        _ = ownership.attach(visible: true, grid: grid)
        let claim = ownership.claimIfOwnerlessOrCurrent(grid: grid)
        ownershipSnapshot = claim.snapshot
        lock.unlock()
    }

    private func writeAllowed() -> Bool {
        guard let ownership else { return true }
        // One store snapshot, not two: derive the write gate from the same
        // snapshot we cache. This runs on every PTY byte chunk libghostty
        // emits, so taking a second snapshot just to recompute ownership was
        // pure waste (an extra lock acquisition + allocation) on the hottest
        // input path.
        let snapshot = ownership.snapshot(fallbackGrid: .daemonFallback)
        let allowed = snapshot.ownerClientID == ownership.clientID
            && snapshot.ownerKind == ownership.kind
        lock.lock()
        ownershipSnapshot = snapshot
        lock.unlock()
        return allowed
    }

    private func authorizeOwnerResizeLocked(_ resize: PendingResize) -> AuthorizedResize? {
        guard let ownership else { return AuthorizedResize(resize: resize, epoch: 0) }
        guard Self.displayGrid(from: resize) != nil else { return nil }
        let fallback = fallbackDisplayGridLocked()
        let snapshot = ownership.snapshot(fallbackGrid: fallback)
        ownershipSnapshot = snapshot
        guard snapshot.ownerClientID == ownership.clientID,
              snapshot.ownerKind == ownership.kind else {
            return nil
        }
        return AuthorizedResize(resize: resize, epoch: snapshot.epoch)
    }

    private func commitOwnerResizeLocked(
        _ authorized: AuthorizedResize
    ) -> (accepted: Bool, snapshot: DisplayOwnershipSnapshot?) {
        guard let ownership else { return (true, nil) }
        guard let grid = Self.displayGrid(from: authorized.resize) else { return (false, ownershipSnapshot) }
        let result = ownership.ownerResize(epoch: authorized.epoch, grid: grid)
        ownershipSnapshot = result.snapshot
        return (result.accepted, result.snapshot)
    }

    private func repairSession(_ session: HostManagedZmxSession, to snapshot: DisplayOwnershipSnapshot) {
        // Ownership snapshots currently carry only the authoritative grid.
        // Do not attach this follower's local pixel dimensions to another
        // client's repair; zero preserves the grid-only semantics used by
        // web/iOS owners until ownership itself becomes pixel-aware.
        try? session.resize(windowSize: Self.gridOnlyWindowSize(snapshot.grid))
    }

    private static func gridOnlyWindowSize(_ grid: DisplayGrid) -> PendingResize {
        PendingResize(cols: grid.cols, rows: grid.rows)
    }

    private func fallbackDisplayGridLocked() -> DisplayGrid {
        if let grid = currentWindowSize().flatMap(Self.displayGrid(from:)) {
            return grid
        }
        if let grid = currentGridSize().flatMap(Self.displayGrid(fromGridSize:)) {
            return grid
        }
        if let lastWithheldResize,
           let grid = Self.displayGrid(from: lastWithheldResize) {
            return grid
        }
        if let pendingResize,
           let grid = Self.displayGrid(from: pendingResize) {
            return grid
        }
        return ownershipSnapshot?.grid ?? .daemonFallback
    }

    private static func displayGrid(
        fromGridSize size: (cols: UInt16, rows: UInt16)
    ) -> DisplayGrid? {
        return try? DisplayGrid(cols: size.cols, rows: size.rows)
    }

    private static func displayGrid(from resize: PendingResize) -> DisplayGrid? {
        try? DisplayGrid(cols: resize.cols, rows: resize.rows)
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
