import Foundation
import Darwin

/// Per-WebSocket bridge between the client and a single `zmx attach`
/// child. Decoupled from NIO so `WebServer` owns the NIO plumbing
/// and `WebSession` stays testable over any byte-pipe.
///
/// The session spawns the child on init (`start()`), spawns a reader
/// thread that blocks on `read(masterFD)`, and exposes `write(_:)`
/// (for binary frames from the client) and `resize(cols:rows:)`
/// (for control frames). On `close()`, sends SIGTERM to the child
/// and closes the master fd.
public final class WebSession {

    public struct Config {
        public let zmxExecutable: URL
        public let zmxDir: URL
        public let sessionName: String
        public init(zmxExecutable: URL, zmxDir: URL, sessionName: String) {
            self.zmxExecutable = zmxExecutable
            self.zmxDir = zmxDir
            self.sessionName = sessionName
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

    private let config: Config
    private var spawned: PtyProcess.Spawned?
    private var readerThread: Thread?
    private let stateLock = NSLock()
    private var isClosed = false

    public init(config: Config) {
        self.config = config
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard spawned == nil else { throw Error.alreadyStarted }

        let launcher = ZmxLauncher(executable: config.zmxExecutable, zmxDir: config.zmxDir)
        // subprocessEnv strips ZMX_SESSION in addition to setting ZMX_DIR —
        // see ZmxLauncher for why that matters (an inherited ZMX_SESSION
        // silently overrides the positional session arg).
        let env = launcher.subprocessEnv(from: ProcessInfo.processInfo.environment)
        do {
            spawned = try PtyProcess.spawn(
                argv: launcher.attachArgv(sessionName: config.sessionName),
                env: env
            )
        } catch {
            throw Error.spawnFailed(error)
        }
        startReaderThread()
    }

    public func write(_ data: Data) {
        guard let fd = spawned?.masterFD, !data.isEmpty else { return }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var offset = 0
            while offset < buf.count {
                let n = Darwin.write(fd, base.advanced(by: offset), buf.count - offset)
                if n < 0 { break }
                offset += n
            }
        }
    }

    public func resize(cols: UInt16, rows: UInt16) {
        guard let fd = spawned?.masterFD else { return }
        try? PtyProcess.resize(masterFD: fd, cols: cols, rows: rows)
    }

    public func close() {
        stateLock.lock()
        if isClosed { stateLock.unlock(); return }
        isClosed = true
        let spawned = self.spawned
        // Drop callback references under the lock so a reader-thread EOF that
        // races with close() can't re-enter the channel after the caller has
        // already handled the close path.
        onPTYData = nil
        onExit = nil
        stateLock.unlock()

        if let spawned {
            // Straight to SIGKILL; zmx attach exiting gracefully is not
            // required (its daemon handles abrupt client disconnect).
            // Closing masterFD unblocks the reader thread's read() —
            // it returns -1/EIO and the thread exits.
            _ = kill(spawned.pid, SIGKILL)
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
        thread.name = "WebSession.reader(\(config.sessionName))"
        thread.start()
        readerThread = thread
    }

    private func dispatchPTYData(_ data: Data) {
        stateLock.lock()
        let cb = onPTYData
        stateLock.unlock()
        cb?(data)
    }

    private func dispatchExit() {
        stateLock.lock()
        let cb = onExit
        stateLock.unlock()
        cb?()
    }
}
