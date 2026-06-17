import Foundation
import GhosttyKit
import GrafttyKit
import os

protocol HostManagedZmxSession: AnyObject {
    func start() throws
    func write(_ data: Data) throws
    func resize(cols: UInt16, rows: UInt16) throws
    func close()
}

extension NativePtySession: HostManagedZmxSession {}

/// Render-desync diagnostic trail (TERM-11.x): every PTY-resize decision
/// the host-managed backend makes, with the inputs that drove it.
/// `log stream --predicate 'subsystem == "com.graftty.app" AND
/// category == "resize-trace"'`.
enum ResizeTrace {
    static let log = Logger(subsystem: "com.graftty.app", category: "resize-trace")
}

final class HostManagedZmxBackend {
    private static var trace: Logger { ResizeTrace.log }

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
    /// to the current grid (TERM-11.3) — deferred to layout-settle when it
    /// fires pre-layout (TERM-11.6). Only bytes emitted during a real user
    /// key dispatch count as user input (TERM-11.8).
    private enum AttachState {
        case silent
        case engaged
    }

    private struct PendingResize: Equatable {
        let cols: UInt16
        let rows: UInt16
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
        // TERM-11.8: engagement is opt-in. Only bytes emitted while a
        // user key dispatch is in flight (`withUserInputScope`, entered
        // by the view around `ghostty_surface_key` for real key events)
        // count as IOS-12.1 user input. Everything else libghostty
        // emits on its own — terminal-query auto-responses (DA/DSR),
        // mouse reporting, focus events — reaches the PTY without
        // engaging. The programmatic scope (`withProgrammaticInput`,
        // e.g. the send-pane IPC's synthesized Return) still vetoes
        // engagement even inside a user scope.
        try? backend.write(data, claimEngagement: backend.emittedBytesClaimEngagement)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, _, _ in
        guard let userdata else { return }
        guard let backend = HostManagedZmxBackend.backend(from: userdata) else { return }

        backend.receiveResize(cols: cols, rows: rows)
    }

    private let spawnConfiguration: ZmxSpawnConfiguration
    private let initialSize: (cols: UInt16, rows: UInt16)?
    private let scheduleCoalescedResize: ResizeCoalescingScheduler
    private let sessionFactory: SessionFactory
    private let lock = NSLock()

    private var lifecycle: Lifecycle = .idle
    private var session: HostManagedZmxSession?
    private var pendingResize: PendingResize?

    /// TERM-11.12: writes arriving before the session starts (e.g.
    /// `pane add --command` typing before the pane's first layout under
    /// TERM-11.10's deferred attach). Delivered in order by `start()`,
    /// after any queued resize; engagement is claimed only when a
    /// queued write actually reaches the PTY.
    private var pendingWrites: [(data: Data, claimEngagement: Bool)] = []
    private var attachState: AttachState = .silent
    private var lastSilentResize: PendingResize?
    private var userdataPointer: UnsafeMutableRawPointer!

    /// TERM-11.9 coalescing state. `coalesceCancel != nil` means the
    /// quiet window is open: forwarded resizes opened it, and any resize
    /// arriving while it's open parks in `pendingCoalescedResize`
    /// (latest wins) until the window expires. `lastForwardedResize`
    /// suppresses redundant trailing SIGWINCHes.
    private var coalesceCancel: (() -> Void)?
    private var pendingCoalescedResize: PendingResize?
    private var lastForwardedResize: PendingResize?

    /// TERM-11.11: one-shot anchor-heal bounce armed by the owning
    /// SurfaceHandle for rehydrated panes (attaching to a pre-existing
    /// session whose TUI may hold a stranded render anchor).
    private var healAnchorOnAttach = false

    /// Delay before the heal's shrink leg: libghostty asynchronously
    /// re-reports the settled size ~25ms after the settle flush, and a
    /// synchronous shrink raced that echo — the PTY went rows-1 → rows
    /// within milliseconds, a coalesced double SIGWINCH that repainted
    /// nothing (and could itself corrupt a mid-frame TUI). Both legs
    /// fire from quiet.
    private static let anchorHealShrinkDelay: TimeInterval = 0.15

    /// Spacing between the heal's shrink and restore legs. TUIs coalesce
    /// rapid SIGWINCHes and skip repainting when the final size equals
    /// their belief — the restore must land only after the TUI observed
    /// the shrunken size.
    private static let anchorHealRestoreDelay: TimeInterval = 0.25

    /// Reentrant counter tracking active `withProgrammaticInput` scopes.
    /// While > 0, `receiveBufferCallback` treats the inbound bytes as
    /// automation and passes `claimEngagement: false` to `write`.
    /// IOS-12.1.
    private var programmaticInputDepth: Int = 0

    /// Reentrant counter tracking active `withUserInputScope` bodies.
    /// TERM-11.8: engagement is opt-in — `receiveBufferCallback` claims
    /// IOS-12.1 engagement only while a user key dispatch is in flight
    /// (the view wraps `ghostty_surface_key` for real key events in this
    /// scope). Bytes libghostty emits on its own — terminal-query
    /// auto-responses (DA/DSR replies), mouse-reporting sequences,
    /// focus events — never engage.
    private var userInputDepth: Int = 0

    /// TERM-11.x gating inputs. `hasRemoteClient` is injected at init
    /// (default false — direct-shell/test backends have no remote peers).
    /// The surface-sync closures are bound by SurfaceHandle after
    /// ghostty_surface_new succeeds, before start(surface:).
    private let hasRemoteClient: () -> Bool
    private var currentGridSize: () -> (cols: UInt16, rows: UInt16)? = { nil }
    private var requestRefresh: () -> Void = {}

    /// Flips true (once) when the owning NSView first receives a nonzero
    /// frame. Pre-settle viewport callbacks are never forwarded in ANY
    /// engagement state — they are libghostty pre-layout noise (the
    /// original PR #201 bug; TERM-11.7).
    private var layoutSettled = false

    init(
        spawnConfiguration: ZmxSpawnConfiguration,
        initialSize: (cols: UInt16, rows: UInt16)? = nil,
        hasRemoteClient: @escaping () -> Bool = { false },
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
        self.hasRemoteClient = hasRemoteClient
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
            // IOS-12.1: each fresh attach starts silent. Pre-layout
            // viewport callbacks are recorded but never propagated (the
            // post-reattach width-drift bug from libghostty's pre-layout
            // callback); once layout settles, silent-state callbacks
            // forward unless a remote client is attached (TERM-11.2).
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

        // TERM-11.10: spawn at the live grid size when the surface-sync
        // provider is bound (it is, before any deferred start) — the
        // construction-time initialSize is the eviction-cache fallback
        // and can be stale relative to the settled layout.
        lock.lock()
        let gridQuery = currentGridSize
        lock.unlock()
        let spawnSize = gridQuery() ?? initialSize
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
                    lock.unlock()
                    try? newSession.resize(cols: resize.cols, rows: resize.rows)
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
                        try? newSession.write(entry.data)
                        if entry.claimEngagement {
                            markUserInput()
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
    /// - Parameter claimEngagement: When `true` (default), this write
    ///   counts as user input under IOS-12.1: the silent gate flips to
    ///   `.engaged` AFTER the write succeeds, flushing any queued
    ///   viewport size to the PTY. Programmatic call sites (initial
    ///   `extraInitialInput`, `typeText` from `splitPane`/`send-pane`,
    ///   the idle-agent nudge writer) pass `false` so they don't
    ///   silently claim a user-input contract they don't represent.
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

        let currentSession = try activeSession()
        try currentSession.write(data)

        // IOS-12.1: flip the gate only AFTER a successful write — a write
        // that fails inside the session shall not disengage the silent
        // gate.
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
        currentGridSize: @escaping () -> (cols: UInt16, rows: UInt16)?,
        requestRefresh: @escaping () -> Void
    ) {
        lock.lock()
        self.currentGridSize = currentGridSize
        self.requestRefresh = requestRefresh
        lock.unlock()
    }

    /// The single spelling of the resize gate — two orthogonal withhold
    /// conditions:
    /// 1. Layout hasn't settled: pre-layout dims are libghostty
    ///    placeholder noise, withheld in EVERY engagement state
    ///    (TERM-11.7).
    /// 2. The pane is still silent with a remote client attached: the
    ///    Mac must not steal the session width without user engagement
    ///    (TERM-11.2 / IOS-12.1).
    /// Caller holds `lock`.
    private func shouldWithholdResizeLocked() -> Bool {
        if !layoutSettled { return true }
        if case .silent = attachState { return hasRemoteClient() }
        return false
    }

    /// TERM-11.1 / TERM-11.6: the owning NSView received its first
    /// nonzero frame. One-shot: sync the PTY to the current grid so zmx
    /// formats output for the dims libghostty is actually rendering —
    /// unless the pane is still silent with a remote client attached
    /// (IOS-12.1 withholding). An engaged pane always syncs here: this
    /// is where an engagement that fired pre-layout lands its deferred
    /// flush instead of shipping the bogus pre-layout grid.
    func markLayoutSettled() {
        lock.lock()
        defer { lock.unlock() }
        guard !layoutSettled else { return }
        layoutSettled = true
        guard !shouldWithholdResizeLocked() else {
            Self.trace.notice("layoutSettled \(self.spawnConfiguration.sessionName, privacy: .public) NO-SYNC remote=\(self.hasRemoteClient())")
            return
        }
        // Refresh deliberately dropped: setFrameSize already issued one
        // on this same frame event two statements before notifying us.
        _ = flushSizeToPtyLocked(reason: "layoutSettled")
        performAnchorHealLocked()
    }

    /// TERM-11.11: arms the one-shot anchor-heal bounce. Set by
    /// SurfaceHandle before the deferred start for rehydrated panes.
    func setAnchorHealOnAttach(_ enabled: Bool) {
        lock.lock()
        healAnchorOnAttach = enabled
        lock.unlock()
    }

    /// TERM-11.11: arms the heal after the settle flush recorded the
    /// settled size. Caller holds `lock`. A reattached TUI repaints
    /// relative to a possibly-stranded anchor and width-only changes
    /// repaint in place — only a ROW change forces the bottom re-anchor
    /// (verified manually 2026-06-11). Both legs are DELAYED: the shrink
    /// must not race libghostty's post-settle viewport echo, and the
    /// restore must not race the shrink (signal coalescing swallows
    /// rapid same-final-size sequences).
    private func performAnchorHealLocked() {
        guard healAnchorOnAttach else { return }
        healAnchorOnAttach = false
        scheduleAnchorHealBounceLocked()
    }

    /// Schedules the rows bounce (rows → rows-1 → rows) that forces the
    /// session's TUI to re-anchor via a spaced pair of full repaints.
    /// Caller holds `lock`. Shared by the reattach heal (TERM-11.11) and
    /// the worktree re-show re-anchor (TERM-11.14). No-op unless running,
    /// not remote-shared (the Mac must not perturb a shared session's
    /// size), and the last forwarded size is healable (≥ 2 rows).
    private func scheduleAnchorHealBounceLocked() {
        guard case .running = lifecycle,
              !hasRemoteClient(),
              let settled = lastForwardedResize,
              settled.rows >= 2 else { return }
        // Cancel handles deliberately dropped: each leg re-checks
        // lifecycle and supersession under the lock when it fires.
        _ = scheduleCoalescedResize(Self.anchorHealShrinkDelay) { [weak self] in
            self?.anchorHealShrink(from: settled)
        }
    }

    /// TERM-11.14: a kept-alive (occluded, not evicted) pane was switched
    /// back to. Even when the grid and PTY size already agree, zmx's render
    /// anchor can be stranded — content drawn while the surface was
    /// occluded sits at the wrong rows, and a same-size `ghostty_surface_
    /// refresh` cannot clear it (it just repaints libghostty's already-
    /// wrong grid). Only a full zmx repaint re-anchors, so force one with
    /// the same rows bounce the reattach heal uses. No-op while a divider
    /// drag is in flight (don't fight the coalescer) or before layout
    /// settles (a pre-layout pane has no real anchor; its attach flow heals
    /// it); the bounce itself is further gated on running / no-remote /
    /// healable rows.
    func reanchorOnShow() {
        lock.lock()
        defer { lock.unlock() }
        guard layoutSettled, coalesceCancel == nil else {
            Self.trace.notice("reanchorOnShow \(self.spawnConfiguration.sessionName, privacy: .public) SKIP settled=\(self.layoutSettled) dragging=\(self.coalesceCancel != nil)")
            return
        }
        Self.trace.notice("reanchorOnShow \(self.spawnConfiguration.sessionName, privacy: .public) bounce")
        scheduleAnchorHealBounceLocked()
    }

    /// TERM-11.11 shrink leg. Fires only when the last size the PTY saw
    /// is still the settled size — the post-settle echo re-forwards that
    /// same size (fine), while a REAL resize changes it and abandons the
    /// heal (that resize already repainted the TUI).
    private func anchorHealShrink(from settled: PendingResize) {
        lock.lock()
        guard case .running = lifecycle, lastForwardedResize == settled else {
            lock.unlock()
            Self.trace.notice("anchorHeal \(self.spawnConfiguration.sessionName, privacy: .public) ABANDONED (superseded before shrink)")
            return
        }
        let shrunk = PendingResize(cols: settled.cols, rows: settled.rows - 1)
        lastForwardedResize = shrunk
        let currentSession = session
        _ = scheduleCoalescedResize(Self.anchorHealRestoreDelay) { [weak self] in
            self?.anchorHealRestore(to: settled)
        }
        lock.unlock()

        Self.trace.notice("anchorHeal \(self.spawnConfiguration.sessionName, privacy: .public) leg1 -> \(shrunk.cols)x\(shrunk.rows)")
        try? currentSession?.resize(cols: shrunk.cols, rows: shrunk.rows)
    }

    /// TERM-11.11 restore leg: return to the settled rows unless another
    /// resize intervened (that resize already repainted the TUI).
    private func anchorHealRestore(to settled: PendingResize) {
        lock.lock()
        let expected = PendingResize(cols: settled.cols, rows: settled.rows - 1)
        guard case .running = lifecycle, lastForwardedResize == expected else {
            lock.unlock()
            Self.trace.notice("anchorHeal \(self.spawnConfiguration.sessionName, privacy: .public) restore SKIPPED (superseded)")
            return
        }
        lastForwardedResize = settled
        let currentSession = session
        lock.unlock()

        Self.trace.notice("anchorHeal \(self.spawnConfiguration.sessionName, privacy: .public) leg2 -> \(settled.cols)x\(settled.rows)")
        try? currentSession?.resize(cols: settled.cols, rows: settled.rows)
    }

    /// TERM-11.4: the last remote client detached from this session. A
    /// still-silent pane syncs the PTY to the current grid immediately —
    /// there is no longer anyone whose width we must preserve. Re-checks
    /// the gate because the registry fires its observer outside its lock:
    /// another client may have re-attached by the time this runs.
    func remoteClientsDidDetach() {
        lock.lock()
        guard case .silent = attachState, !shouldWithholdResizeLocked() else {
            lock.unlock()
            Self.trace.notice("remoteClientsDidDetach \(self.spawnConfiguration.sessionName, privacy: .public) NO-SYNC")
            return
        }
        let refresh = flushSizeToPtyLocked(reason: "remoteDetach")
        lock.unlock()
        refresh?()
    }

    /// TERM-11.13: a pane re-entered the visible set (un-occluded). While it
    /// was occluded the window's grid may have drifted to a row/col count the
    /// PTY never received: libghostty emits a viewport callback only on a grid
    /// *delta*, and an occluded surface re-shown at a size it already held
    /// produces none, so the PTY keeps its stale latched dims and the
    /// session's TUI renders off-anchor (the "off by N lines" desync) until a
    /// real resize forces a SIGWINCH — which is exactly why a manual vertical
    /// resize fixes it. Reconcile here by forwarding the live grid to the PTY
    /// when it differs from what the PTY last saw, then force a refresh so the
    /// TUI re-anchors. No-op when already in agreement (so plain focus
    /// switches don't churn SIGWINCHes through the session) or while resize
    /// withholding applies (pre-layout, or a still-silent pane with a remote
    /// client whose width the Mac must not steal — IOS-12.1 / TERM-11.2).
    func resyncVisibleGrid() {
        lock.lock()
        guard case .running = lifecycle,
              !shouldWithholdResizeLocked(),
              let grid = currentGridSize() else {
            lock.unlock()
            return
        }
        guard PendingResize(cols: grid.cols, rows: grid.rows) != lastForwardedResize else {
            lock.unlock()
            // .debug, not .notice: the in-sync no-op is the common case on
            // every plain focus switch — keep it out of the persisted log.
            Self.trace.debug("resyncVisibleGrid \(self.spawnConfiguration.sessionName, privacy: .public) IN-SYNC \(grid.cols)x\(grid.rows)")
            return
        }
        let refresh = flushSizeToPtyLocked(reason: "showResync")
        lock.unlock()
        refresh?()
    }

    /// Single-lock snapshot of the engagement decision for bytes arriving
    /// via `receiveBufferCallback` (a hot path — fires for every chunk
    /// libghostty emits): engage iff a user key dispatch is in flight
    /// (TERM-11.8) and no programmatic scope vetoes it (IOS-12.1).
    fileprivate var emittedBytesClaimEngagement: Bool {
        lock.lock()
        defer { lock.unlock() }
        return userInputDepth > 0 && programmaticInputDepth == 0
    }

    /// Runs `body` with the user-input flag raised: bytes libghostty
    /// emits through `receiveBufferCallback` during `body` count as
    /// IOS-12.1 user input and engage the silent gate. The view wraps
    /// real key-event dispatch (`ghostty_surface_key` from `keyDown` /
    /// `keyUp`) in this scope. TERM-11.8. Reentrant via a depth counter.
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
        // No `attachState` / `lastSilentResize` reset here: `.closed` is
        // terminal and `start()` rejects it (`Error.closed`), so there
        // is no "next attach" on this instance. Per-process reattach is
        // handled by constructing a fresh `HostManagedZmxBackend`.
        lock.unlock()

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

    private func receiveResize(cols: UInt16, rows: UInt16) {
        let currentSession: HostManagedZmxSession?

        lock.lock()
        // TERM-11.7 / TERM-11.2 / IOS-12.1: withhold while layout hasn't
        // settled (pre-layout libghostty noise — regardless of engagement
        // state) or while a still-silent pane has a remote client attached
        // (the Mac must not steal the session width without user
        // engagement). Otherwise forward without engaging.
        if shouldWithholdResizeLocked() {
            let settled = layoutSettled
            let remote = hasRemoteClient()
            lastSilentResize = PendingResize(cols: cols, rows: rows)
            lock.unlock()
            Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(cols)x\(rows) WITHHELD settled=\(settled) remote=\(remote)")
            return
        }
        // Forwarding live dims supersedes anything withheld earlier;
        // clearing keeps the engagement flush's fallback from
        // resurrecting a stale size when no grid provider is bound.
        lastSilentResize = nil
        switch lifecycle {
        case .idle, .starting:
            pendingResize = PendingResize(cols: cols, rows: rows)
            currentSession = nil
        case .running:
            // TERM-11.9: while the quiet window is open (a drag in
            // progress), park the latest size instead of forwarding —
            // the window's trailing fire delivers it.
            if coalesceCancel != nil {
                pendingCoalescedResize = PendingResize(cols: cols, rows: rows)
                lock.unlock()
                Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(cols)x\(rows) COALESCED")
                return
            }
            lastForwardedResize = PendingResize(cols: cols, rows: rows)
            openCoalesceWindowLocked()
            currentSession = session
        case .closed:
            currentSession = nil
        }
        lock.unlock()

        Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(cols)x\(rows) \(currentSession != nil ? "FORWARDED" : "QUEUED", privacy: .public)")
        try? currentSession?.resize(cols: cols, rows: rows)
    }

    /// Opens the TERM-11.9 quiet window. Caller holds `lock`. The
    /// scheduler only enqueues the trailing fire (no synchronous
    /// callback, no backend re-entry), so invoking it under the lock is
    /// safe — same contract as `hasRemoteClient`.
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
        if pending == lastForwardedResize {
            lock.unlock()
            return
        }
        lastForwardedResize = pending
        openCoalesceWindowLocked()
        let currentSession = session
        lock.unlock()

        Self.trace.notice("receiveResize \(self.spawnConfiguration.sessionName, privacy: .public) \(pending.cols)x\(pending.rows) TRAILING")
        try? currentSession?.resize(cols: pending.cols, rows: pending.rows)
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
        guard case .silent = attachState else {
            lock.unlock()
            return
        }
        attachState = .engaged
        // TERM-11.6: engagement before the first real layout must not
        // flush — the grid still holds libghostty's pre-layout
        // placeholder dims (the 49x17 bounce captured in the 2026-06-10
        // resize-trace). markLayoutSettled performs the sync instead.
        guard layoutSettled else {
            lock.unlock()
            Self.trace.notice("engagement \(self.spawnConfiguration.sessionName, privacy: .public) DEFERRED (layout not settled)")
            return
        }
        let refresh = flushSizeToPtyLocked(reason: "engagement")
        lock.unlock()
        refresh?()
    }

    /// Shared sync tail for markUserInput / markLayoutSettled /
    /// remoteClientsDidDetach / resyncVisibleGrid. Caller holds `lock`.
    /// Resolves the sync target — the live grid when a provider is bound,
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
        // what keeps a bound `currentGridSize` surface pointer from being
        // dereferenced after the surface is gone.
        if case .closed = lifecycle { return nil }
        let queued = lastSilentResize
        lastSilentResize = nil
        let grid = currentGridSize()
        let target = grid ?? queued.map { (cols: $0.cols, rows: $0.rows) }
        guard let target else {
            Self.trace.notice("flush(\(reason, privacy: .public)) \(self.spawnConfiguration.sessionName, privacy: .public) NO-TARGET")
            return nil
        }
        Self.trace.notice("flush(\(reason, privacy: .public)) \(self.spawnConfiguration.sessionName, privacy: .public) -> \(target.cols)x\(target.rows) fromGrid=\(grid != nil) queued=\(queued.map { "\($0.cols)x\($0.rows)" } ?? "nil", privacy: .public)")
        switch lifecycle {
        case .running:
            // TERM-11.9: the flush supersedes any mid-drag size parked
            // in the quiet window — a stale coalesced resize must not
            // land after this authoritative sync.
            pendingCoalescedResize = nil
            lastForwardedResize = PendingResize(cols: target.cols, rows: target.rows)
            try? session?.resize(cols: target.cols, rows: target.rows)
            return requestRefresh
        case .idle, .starting:
            pendingResize = PendingResize(cols: target.cols, rows: target.rows)
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
