import Foundation
import Darwin

/// PTY-backed `zmx attach` engine shared by the `/ws` WebSocket bridge
/// (via the `WebSession` adapter) and the SSH-over-WebRTC `terminal`
/// channel (directly, as a `TerminalByteStream`).
///
/// Originally two engines existed: `WebSession`'s real PTY master (via
/// `ZmxLauncher` + `PtyProcess.spawn`) and `ZmxAttachStream`'s
/// `Process`+`Pipe` duplicate, whose `resize` landed on a pipe fd and
/// silently no-op'd (ENOTTY) — SSH window-change never reached the PTY.
/// This type is the one engine both paths now share, so SSH gets the
/// same real `ioctl(TIOCSWINSZ)` resize as `/ws`.
///
/// The engine spawns the child on `start()`, spawns a reader thread
/// that blocks on `read(masterFD)`, and a size-poller thread that
/// watches the PTY's winsize. It exposes two consumption surfaces:
///   - Callbacks (`onPTYData`/`onExit`/`onPTYSize`) plus synchronous
///     `write(_:)`/`resize(cols:rows:)`/`close()`, used by `WebSession`.
///   - `TerminalByteStream`'s async `send`/`resize`/`close` plus the
///     `inboundBytes` `AsyncStream`, used by `TerminalChannelHandler`.
/// Both surfaces observe the same underlying PTY; `dispatchPTYData` and
/// `dispatchExit` feed both the callbacks and the `AsyncStream`.
///
/// **Pick exactly one delivery surface per instance.** `start()` locks in
/// which surface `dispatchPTYData` feeds by checking whether `onPTYData`
/// is already installed at that moment: if so, PTY output is delivered to
/// `onPTYData` only and `inboundBytes` receives nothing and buffers
/// nothing; otherwise PTY output goes to `inboundBytes` only. `WebSession`
/// sets `onPTYData` before calling `start()`, so its engine is
/// callback-mode; `TerminalSessionHandler` (the SSH path) never sets
/// `onPTYData`, so its engine is stream-mode. The unselected surface
/// isn't merely idle — `inboundBytes` is an `AsyncStream` with the
/// default `.unbounded` buffering policy, so an engine that yielded into
/// it regardless of whether anything ever iterates it would retain every
/// PTY output chunk for the session's lifetime (unbounded memory growth
/// on the callback surface, which nothing drains). Setting `onPTYData`
/// AFTER `start()` on a stream-mode engine does not switch surfaces —
/// the choice is made once, at `start()`. `onPTYSize`/`onExit` are not
/// part of this either/or split — they're safe to set regardless of
/// which byte-delivery surface a caller uses.
///
/// On `close()`, sends SIGTERM to the child and closes the master fd.
/// SIGTERM (not SIGKILL) per WEB-4.5 so the client exits gracefully
/// while the daemon survives.
public final class ZmxAttachEngine: TerminalByteStream, TerminalSizeReporting, TerminalSyncResizing, @unchecked Sendable {

    public struct Config {
        public let zmxExecutable: URL
        public let zmxDir: URL
        public let sessionName: String
        public let workingDirectory: URL?
        public init(
            zmxExecutable: URL,
            zmxDir: URL,
            sessionName: String,
            workingDirectory: URL? = nil
        ) {
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.sessionName = sessionName
            self.workingDirectory = workingDirectory
        }
    }

    public enum Error: Swift.Error {
        case notStarted
        case alreadyStarted
        case spawnFailed(Swift.Error)
    }

    /// Called on each chunk read from the PTY. Invoked off the caller's
    /// thread (from the reader thread). Caller is responsible for thread
    /// safety in the callback (e.g., dispatching onto NIO's event loop).
    public var onPTYData: ((Data) -> Void)?

    /// Called when the PTY reader observes EOF or an error, signaling
    /// that the zmx attach child exited (shell exit, session ended,
    /// or error). The caller should initiate WS close.
    public var onExit: (() -> Void)?

    /// Called whenever a size-poll observes the PTY's winsize has
    /// changed, plus once on initial start after `zmx attach` has
    /// applied the session's size. The caller forwards this to the
    /// client as a `WebControlEnvelope.grid` text frame so it can size
    /// its rendering surface to match the server.
    ///
    /// Lock-guarded (unlike `onPTYData`/`onExit`, whose only writer —
    /// `WebSession` — assigns them before `start()` spawns any thread):
    /// the SSH path (`TerminalSessionHandler`, via `TerminalSizeReporting`)
    /// installs this callback from a NIO event loop AFTER `start()`, so
    /// an unguarded write would race the size-poller thread's read and
    /// `closeSync()`'s clear. Installing a callback while a size is
    /// already known immediately re-emits that size to the new callback
    /// (outside the lock), so a late installer doesn't miss the
    /// initial-attach emission the poller may have already delivered to
    /// nobody.
    public var onPTYSize: ((_ cols: UInt16, _ rows: UInt16) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _onPTYSize
        }
        set {
            stateLock.lock()
            _onPTYSize = newValue
            let known = lastKnownSize
            let closed = isClosed
            stateLock.unlock()
            if !closed, let newValue, let known {
                newValue(known.cols, known.rows)
            }
        }
    }
    private var _onPTYSize: ((_ cols: UInt16, _ rows: UInt16) -> Void)?

    /// `TerminalByteStream.inboundBytes`: the same PTY bytes delivered
    /// to `onPTYData`, for consumers that prefer the async-stream
    /// surface (`TerminalChannelHandler`) over the callback surface.
    /// Finished exactly once, from `closeSync()`, on either explicit
    /// `close()` or reader-thread EOF.
    public let inboundBytes: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation

    private let config: Config
    private var spawned: PtyProcess.Spawned?
    private var readerThread: Thread?
    private var sizePoller: Thread?
    private var lastKnownSize: (cols: UInt16, rows: UInt16)?
    private let stateLock = NSLock()
    private var isClosed = false

    /// Which delivery surface `dispatchPTYData` feeds bytes to, locked in
    /// exactly once by `start()` before the reader thread that would call
    /// `dispatchPTYData` even exists. Determined by whether `onPTYData` is
    /// already installed at that moment: `WebSession`/`WebServer` always
    /// assign `onPTYData` before calling `start()`, and the SSH path
    /// (`TerminalSessionHandler`) never assigns it at all — so this read
    /// is a deterministic snapshot, not a race against whichever surface
    /// a caller installs later.
    private enum DeliverySurface {
        case callback
        case stream
    }
    private var deliverySurface: DeliverySurface = .stream

    /// Test seam: count of PTY chunks yielded into `inboundBytes`. Exists
    /// so tests can assert the unselected delivery surface buffers
    /// nothing without reaching into `AsyncStream` internals (which don't
    /// expose buffer contents). Incremented only inside `dispatchPTYData`,
    /// guarded by `stateLock` like the rest of the dispatch state.
    var streamYieldCountForTesting: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _streamYieldCountForTesting
    }
    private var _streamYieldCountForTesting = 0

    /// Per-session typed-but-uncommitted-byte tracker (TEAM-IDLE-2.2). Optional
    /// because not all callers need it (tests, future non-Codex uses); set by
    /// the caller that owns the shared instance. When non-nil, each
    /// `write(_:)` chunk is reported under `config.sessionName` and
    /// `close()` clears the entry.
    public var inputState: ZmxInputState?

    /// TERM-11.5: per-session remote attach counts. Set by the owning
    /// caller before `start()`; `start()` registers this attach and
    /// `close()` deregisters it exactly once (`spawned != nil` is the
    /// registered-attach marker — both are set by the same successful
    /// spawn, and `isClosed` makes close() single-entry).
    public var attachmentRegistry: RemoteAttachmentRegistry?

    /// Test seam: override the env `start()` reads for terminal-capability
    /// resolution. Production callers leave this nil and `start()` reads
    /// `ProcessInfo.processInfo.environment` directly. Tests inject SHELL
    /// and GHOSTTY_RESOURCES_DIR through here so the test doesn't depend on
    /// the CI runner's environment.
    var processEnvForTesting: [String: String]?

    public init(config: Config) {
        self.config = config
        var cont: AsyncStream<Data>.Continuation!
        self.inboundBytes = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard spawned == nil else { throw Error.alreadyStarted }

        // Lock in the delivery surface before any thread that could call
        // dispatchPTYData exists (startReaderThread(), below, is the
        // first). See `deliverySurface`'s doc for why this snapshot is
        // deterministic rather than racy.
        deliverySurface = (onPTYData == nil) ? .stream : .callback

        let launcher = ZmxLauncher(executable: config.zmxExecutable, zmxDir: config.zmxDir)
        let processEnv = processEnvForTesting ?? ProcessInfo.processInfo.environment
        // subprocessEnv strips ZMX_SESSION in addition to setting ZMX_DIR —
        // see ZmxLauncher for why that matters (an inherited ZMX_SESSION
        // silently overrides the positional session arg).
        var env = launcher.subprocessEnv(from: processEnv)
        // WEB-4.10: this `zmx attach` may win the create-session race
        // against the host pane's own attach (which is delayed behind
        // `git worktree add` + discovery). Whichever attach reaches the
        // daemon first sets the user shell's permanent env, so propagate
        // the same shell-integration env the host pane uses — without
        // this, the mobile-created shell spawns with no TERM (no color)
        // and no ZDOTDIR (no OSC PWD → no `onShellReady` → no default
        // command).
        let ghosttyResourcesDir = processEnv["GHOSTTY_RESOURCES_DIR"]
        ZmxSpawnConfiguration.applyTerminalCapabilities(
            env: &env,
            ghosttyResourcesDir: ghosttyResourcesDir
        )
        ZmxSpawnConfiguration.applyZshShellIntegration(
            env: &env,
            userShellPath: processEnv["SHELL"] ?? "/bin/sh",
            ghosttyResourcesDir: ghosttyResourcesDir
        )
        do {
            spawned = try PtyProcess.spawn(
                argv: launcher.attachArgv(sessionName: config.sessionName),
                env: env,
                currentDirectory: config.workingDirectory
            )
        } catch {
            throw Error.spawnFailed(error)
        }
        // TERM-11.5: only a successful spawn counts as a remote attach —
        // a failed spawn throws above and never registers, so close()
        // has nothing to deregister. Safe under stateLock because attach
        // fires no observer (unlike detach, which close() calls unlocked).
        attachmentRegistry?.attach(sessionName: config.sessionName)
        startReaderThread()
        startSizePoller()
    }

    public func write(_ data: Data) {
        // `closeSync()` closes `spawned?.masterFD` outside `stateLock` and
        // never nils `spawned` itself — checking `isClosed` under the lock
        // first closes the TOCTOU window where a write racing an
        // in-flight `close()` (SSH's write-FIFO consumer and
        // `channelInactive`'s close run on unordered `Task`s) would use a
        // stale fd number the OS may already have reused for something
        // else.
        stateLock.lock()
        let closed = isClosed
        let fd = spawned?.masterFD
        stateLock.unlock()
        guard !closed, let fd, !data.isEmpty else { return }
        // TEAM-IDLE-2.2: track the chunk before we hand it to the PTY so an
        // idle-delivery tick that observes the session right after the write
        // sees the uncommitted-byte count we just produced.
        inputState?.recordInput(data, forSession: config.sessionName)
        try? data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            let typed = base.assumingMemoryBound(to: UInt8.self)
            try SocketIO.writeAll(fd: fd, bytes: typed, count: buf.count)
        }
    }

    /// `TerminalByteStream.send`: same PTY write as `write(_:)`, exposed
    /// as an async throwing method for the `terminal`-channel consumer.
    public func send(_ bytes: Data) async throws {
        write(bytes)
    }

    /// `TerminalSyncResizing`'s synchronous entry point — see `write(_:)`'s
    /// comment for why a closed-fd guard is needed here too (the
    /// size-poller thread's own `isClosed`-under-lock check, just above,
    /// documents the identical fd-reuse race for reads).
    public func resize(cols: UInt16, rows: UInt16) {
        stateLock.lock()
        let closed = isClosed
        let fd = spawned?.masterFD
        stateLock.unlock()
        guard !closed, let fd else { return }
        try? PtyProcess.resize(masterFD: fd, cols: cols, rows: rows)
    }

    /// `TerminalByteStream.resize`: the behavioral upgrade this engine
    /// delivers to the SSH path — an `ioctl(TIOCSWINSZ)` on the real PTY
    /// master, replacing `ZmxAttachStream`'s ENOTTY no-op on a pipe fd.
    public func resize(cols: Int, rows: Int) async {
        resize(cols: UInt16(clamping: cols), rows: UInt16(clamping: rows))
    }

    public func close() {
        closeSync()
    }

    /// `TerminalByteStream.close`: `TerminalChannelHandler.teardown`
    /// relies on `inboundBytes` finishing synchronously with this call
    /// (see the protocol doc) — `closeSync()` finishes the continuation
    /// before returning, so awaiting this is sufficient.
    public func close() async {
        closeSync()
    }

    private func closeSync() {
        stateLock.lock()
        if isClosed { stateLock.unlock(); return }
        isClosed = true
        let spawned = self.spawned
        // Drop callback references under the lock so a reader-thread EOF that
        // races with close() can't re-enter the channel after the caller has
        // already handled the close path. (`_onPTYSize` directly — the
        // computed `onPTYSize` setter takes stateLock, which is already
        // held here and is not recursive.)
        onPTYData = nil
        onExit = nil
        _onPTYSize = nil
        stateLock.unlock()

        // TERM-11.5: a non-nil spawned means start() registered an attach;
        // the isClosed guard above makes this deregistration single-entry.
        // Detach OUTSIDE stateLock: the registry's onLastDetach observer
        // may take other locks (the host-managed backend does), and
        // holding stateLock across it risks deadlock.
        if spawned != nil {
            attachmentRegistry?.detach(sessionName: config.sessionName)
        }

        // TEAM-IDLE-2.2: drop our slot in the shared tracker so a future
        // session that reuses this name doesn't inherit a stale byte count.
        inputState?.removeSession(config.sessionName)

        // Finish the AsyncStream so any `for await` consumer (e.g.
        // `TerminalChannelHandler`) exits its loop. Safe to call even if
        // the reader thread's EOF already finished it — finish() is a
        // documented no-op once the stream has already finished.
        continuation.finish()

        if let spawned {
            // WEB-4.5: SIGTERM (not SIGKILL) so `zmx attach` gets a chance
            // to exit cleanly — flush its read side, log the disconnect,
            // detach from the daemon gracefully. The daemon itself
            // survives either way per ZMX-4.4; this signal targets the
            // short-lived client process we spawned for the web frame.
            // The 500ms waitpid window below accommodates SIGTERM's
            // slightly-slower convergence.
            //
            // Closing masterFD afterwards unblocks the reader thread's
            // read() — it returns -1/EIO and the thread exits.
            _ = kill(spawned.pid, SIGTERM)
            Darwin.close(spawned.masterFD)
            // Bounded nonblocking reap (≤500ms). If waitpid doesn't see
            // the child marked dead in that window, give up and leave it
            // as a zombie rather than block NIO's event loop thread —
            // this is the close() path called from channelInactive.
            var status: Int32 = 0
            for _ in 0..<10 {
                if waitpid(spawned.pid, &status, WNOHANG) != 0 { break }
                usleep(50_000)
            }
        }
    }

    private func startReaderThread() {
        guard let fd = spawned?.masterFD else { return }
        let thread = Thread { [weak self] in
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                self?.dispatchPTYData(Data(buf[0..<n]))
            }
            self?.dispatchExit()
        }
        thread.name = "ZmxAttachEngine.reader(\(config.sessionName))"
        thread.start()
        readerThread = thread
    }

    private func dispatchPTYData(_ data: Data) {
        stateLock.lock()
        let cb = onPTYData
        let surface = deliverySurface
        if surface == .stream { _streamYieldCountForTesting += 1 }
        stateLock.unlock()
        // Exhaustive switch, not an unconditional `cb?(data)` alongside a
        // separate `if surface == .stream` for the stream branch: the two
        // used to be independent, so a stream-mode engine (the SSH path
        // never sets `onPTYData` before `start()`, locking in `.stream`)
        // that later had `onPTYData` assigned anyway — e.g. by a caller
        // that doesn't realize `start()` already locked in the other
        // surface — would double-deliver every chunk: once via `cb?(data)`
        // and once via `continuation.yield(data)`. The switch makes each
        // surface's bytes go through exactly the branch `start()` selected.
        switch surface {
        case .callback:
            cb?(data)
        case .stream:
            // Only the surface selected at start() ever receives bytes —
            // the other one is not just unused, it must not buffer (see
            // the class doc). Without this guard, an AsyncStream's
            // default .unbounded policy retains every chunk nobody will
            // ever drain for the engine's whole lifetime: unbounded
            // per-session memory growth on the callback (`/ws`) surface.
            continuation.yield(data)
        }
    }

    private func dispatchExit() {
        stateLock.lock()
        let cb = onExit
        stateLock.unlock()
        cb?()
        // Reader EOF means the PTY closed; finish the AsyncStream even if
        // the caller never calls close() (e.g. a `TerminalByteStream`
        // consumer whose only close signal is the stream ending).
        continuation.finish()
    }

    /// Polls the PTY winsize on a background thread. Each change is
    /// forwarded to `onPTYSize` so the WebSocket bridge can push a
    /// `grid` control envelope to the client. 250 ms cadence is a
    /// compromise: slow enough to be free CPU-wise, fast enough that a
    /// Mac-side window drag feels responsive to the iOS viewer.
    /// kevent-on-winsize would be cleaner but PTY fds don't support it;
    /// SIGWINCH handling in the parent requires a global signal
    /// disposition change that conflicts with the rest of Graftty.
    private func startSizePoller() {
        guard let fd = spawned?.masterFD else { return }
        let thread = Thread { [weak self] in
            while true {
                guard let self else { break }
                // Single critical section per iteration: check that the
                // session hasn't been closed (the `close()` path sets
                // isClosed=true then Darwin.close(fd)) AND read the last
                // known size. Doing the ioctl *inside* the lock prevents
                // the close+fd-reuse race where a freshly-opened fd of
                // the same integer value would get a spurious TIOCGWINSZ.
                self.stateLock.lock()
                let closed = self.isClosed
                guard !closed else {
                    self.stateLock.unlock()
                    break
                }
                let size = PtyProcess.currentSize(masterFD: fd)
                var emit: (UInt16, UInt16)?
                if let size {
                    let changed = (self.lastKnownSize?.cols != size.cols)
                                || (self.lastKnownSize?.rows != size.rows)
                    if changed {
                        self.lastKnownSize = size
                        emit = (size.cols, size.rows)
                    }
                }
                let cb = self._onPTYSize
                self.stateLock.unlock()
                if let (cols, rows) = emit { cb?(cols, rows) }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        thread.name = "ZmxAttachEngine.sizePoller(\(config.sessionName))"
        thread.start()
        sizePoller = thread
    }
}
