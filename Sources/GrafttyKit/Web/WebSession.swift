import Foundation

/// Per-WebSocket bridge between the client and a single `zmx attach`
/// child. Decoupled from NIO so `WebServer` owns the NIO plumbing
/// and `WebSession` stays testable over any byte-pipe.
///
/// A thin adapter over `ZmxAttachEngine` (the PTY engine also used
/// directly by the SSH-over-WebRTC `terminal` channel as a
/// `TerminalByteStream`). `WebSession` exists as a distinct type only
/// to keep the `/ws` bridge's callback-based API (`onPTYData`,
/// `write(_:)`, `resize(cols: UInt16, rows: UInt16)`) stable; all
/// behavior lives in the shared engine.
public final class WebSession {

    public typealias Config = ZmxAttachEngine.Config
    public typealias Error = ZmxAttachEngine.Error

    private let engine: ZmxAttachEngine

    /// Called on each chunk read from the PTY. Invoked off the caller's
    /// thread (from the reader thread). Caller is responsible for thread
    /// safety in the callback (e.g., dispatching onto NIO's event loop).
    public var onPTYData: ((Data) -> Void)? {
        get { engine.onPTYData }
        set { engine.onPTYData = newValue }
    }

    /// Called when the PTY reader observes EOF or an error, signaling
    /// that the zmx attach child exited (shell exit, session ended,
    /// or error). The caller should initiate WS close.
    public var onExit: (() -> Void)? {
        get { engine.onExit }
        set { engine.onExit = newValue }
    }

    /// Called whenever a size-poll observes the PTY's winsize has
    /// changed, plus once on initial start after `zmx attach` has
    /// applied the session's size. The caller forwards this to the
    /// client as a `WebControlEnvelope.grid` text frame so it can size
    /// its rendering surface to match the server.
    public var onPTYSize: ((_ cols: UInt16, _ rows: UInt16) -> Void)? {
        get { engine.onPTYSize }
        set { engine.onPTYSize = newValue }
    }

    /// Per-session typed-but-uncommitted-byte tracker (TEAM-IDLE-2.2). Optional
    /// because not all `WebSession` callers need it (tests, future non-Codex
    /// uses); set by the caller that owns the shared instance. When non-nil,
    /// each `write(_:)` chunk is reported under `config.sessionName` and
    /// `close()` clears the entry.
    public var inputState: ZmxInputState? {
        get { engine.inputState }
        set { engine.inputState = newValue }
    }

    /// TERM-11.5: per-session remote attach counts. Set by the owning
    /// WebSocket bridge before `start()`; `start()` registers this attach
    /// and `close()` deregisters it exactly once.
    public var attachmentRegistry: RemoteAttachmentRegistry? {
        get { engine.attachmentRegistry }
        set { engine.attachmentRegistry = newValue }
    }

    /// Test seam: override the env `start()` reads for terminal-capability
    /// resolution. Production callers leave this nil and `start()` reads
    /// `ProcessInfo.processInfo.environment` directly. Tests inject SHELL
    /// and GHOSTTY_RESOURCES_DIR through here so the test doesn't depend on
    /// the CI runner's environment.
    var processEnvForTesting: [String: String]? {
        get { engine.processEnvForTesting }
        set { engine.processEnvForTesting = newValue }
    }

    public init(config: Config) {
        self.engine = ZmxAttachEngine(config: config)
    }

    public func start() throws {
        try engine.start()
    }

    public func write(_ data: Data) {
        engine.write(data)
    }

    public func resize(cols: UInt16, rows: UInt16) {
        engine.resize(cols: cols, rows: rows)
    }

    public func close() {
        engine.close()
    }
}
