import Darwin
import Foundation
import GhosttyKit
import GrafttyKit

final class NativePtySession {
    typealias Spawner = (
        _ argv: [String],
        _ env: [String: String],
        _ currentDirectory: URL?,
        _ initialSize: (cols: UInt16, rows: UInt16)?
    ) throws -> PtyProcess.Spawned
    typealias Writer = (
        _ fd: Int32,
        _ bytes: UnsafePointer<UInt8>,
        _ count: Int
    ) throws -> Void
    typealias Resizer = (
        _ fd: Int32,
        _ cols: UInt16,
        _ rows: UInt16
    ) throws -> Void
    typealias Closer = (_ spawned: PtyProcess.Spawned) -> Void
    typealias FDCloser = (_ fd: Int32) -> Void

    enum Error: Swift.Error {
        case alreadyStarted
        case closed
        case notStarted
        case spawnFailed(Swift.Error)
    }

    private enum Lifecycle {
        case idle
        case starting
        case running
        case failed(Swift.Error)
        case closed
    }

    private final class State {
        private let mutex = NSLock()
        var lifecycle: Lifecycle = .idle
        var spawned: PtyProcess.Spawned?
        var readerThread: Thread?
        var writeToSurface: ((Data) -> Void)?
        var processExited: ((pid_t, Int32?) -> Void)?
        var spawnFailed: ((Swift.Error) -> Void)?

        func lock() {
            mutex.lock()
        }

        func unlock() {
            mutex.unlock()
        }
    }

    private let argv: [String]
    private let env: [String: String]
    private let workingDirectory: URL?
    private let initialSize: (cols: UInt16, rows: UInt16)?
    private let spawner: Spawner
    private let writer: Writer
    private let resizer: Resizer
    private let closer: Closer
    private let fdCloser: FDCloser
    private let readerWillStart: ((Int32) -> Void)?
    private let state = State()
    private let ioLock = NSLock()

    init(
        argv: [String],
        env: [String: String],
        workingDirectory: URL?,
        initialSize: (cols: UInt16, rows: UInt16)? = nil,
        writeToSurface: @escaping (Data) -> Void,
        processExited: @escaping (pid_t, Int32?) -> Void,
        spawnFailed: @escaping (Swift.Error) -> Void,
        spawner: @escaping Spawner = { argv, env, currentDirectory, initialSize in
            try PtyProcess.spawn(
                argv: argv,
                env: env,
                currentDirectory: currentDirectory,
                initialSize: initialSize
            )
        },
        writer: @escaping Writer = SocketIO.writeAll,
        resizer: @escaping Resizer = PtyProcess.resize,
        closer: @escaping Closer = NativePtySession.defaultTerminate,
        fdCloser: @escaping FDCloser = { fd in _ = Darwin.close(fd) },
        readerWillStart: ((Int32) -> Void)? = nil
    ) {
        self.argv = argv
        self.env = env
        self.workingDirectory = workingDirectory
        self.initialSize = initialSize
        self.state.writeToSurface = writeToSurface
        self.state.processExited = processExited
        self.state.spawnFailed = spawnFailed
        self.spawner = spawner
        self.writer = writer
        self.resizer = resizer
        self.closer = closer
        self.fdCloser = fdCloser
        self.readerWillStart = readerWillStart
    }

    convenience init(
        surface: ghostty_surface_t,
        argv: [String],
        env: [String: String],
        workingDirectory: URL?,
        initialSize: (cols: UInt16, rows: UInt16)? = nil,
        spawnFailed: @escaping (Swift.Error) -> Void,
        spawner: @escaping Spawner = { argv, env, currentDirectory, initialSize in
            try PtyProcess.spawn(
                argv: argv,
                env: env,
                currentDirectory: currentDirectory,
                initialSize: initialSize
            )
        }
    ) {
        let startedAt = Date()
        self.init(
            argv: argv,
            env: env,
            workingDirectory: workingDirectory,
            initialSize: initialSize,
            writeToSurface: { data in
                data.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                        return
                    }
                    ghostty_surface_write_buffer(surface, base, UInt(data.count))
                }
            },
            processExited: { _, status in
                let runtimeMilliseconds = UInt64(Date().timeIntervalSince(startedAt) * 1000)
                ghostty_surface_process_exit(
                    surface,
                    Self.exitCode(from: status),
                    runtimeMilliseconds
                )
            },
            spawnFailed: spawnFailed,
            spawner: spawner
        )
    }

    deinit {
        close()
    }

    func start() throws {
        state.lock()
        switch state.lifecycle {
        case .closed:
            state.unlock()
            throw Error.closed
        case .idle:
            state.lifecycle = .starting
            state.unlock()
        case .failed(let error):
            state.unlock()
            throw Error.spawnFailed(error)
        case .starting, .running:
            state.unlock()
            throw Error.alreadyStarted
        }

        let newSpawn: PtyProcess.Spawned
        do {
            newSpawn = try spawner(argv, env, workingDirectory, initialSize)
        } catch {
            state.lock()
            if case .starting = state.lifecycle { state.lifecycle = .failed(error) }
            state.unlock()
            notifySpawnFailure(error)
            throw Error.spawnFailed(error)
        }

        state.lock()
        if case .closed = state.lifecycle {
            state.unlock()
            closer(newSpawn)
            fdCloser(newSpawn.masterFD)
            throw Error.closed
        }
        state.spawned = newSpawn
        state.lifecycle = .running
        state.unlock()

        startReaderThread(fd: newSpawn.masterFD, pid: newSpawn.pid)
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        ioLock.lock()
        defer { ioLock.unlock() }

        let fd = try activeMasterFD()
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            try writer(fd, base, buffer.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        ioLock.lock()
        defer { ioLock.unlock() }

        try resizer(activeMasterFD(), cols, rows)
    }

    func close() {
        state.lock()
        if case .closed = state.lifecycle {
            state.unlock()
            return
        }
        state.lifecycle = .closed
        let currentSpawn = state.spawned
        state.writeToSurface = nil
        state.processExited = nil
        state.spawnFailed = nil
        state.unlock()

        if let currentSpawn {
            ioLock.lock()
            terminateAndClose(currentSpawn)
            ioLock.unlock()
        }
    }

    var activeMasterFDForTesting: Int32? {
        state.lock()
        defer { state.unlock() }
        return state.spawned?.masterFD
    }

    private func activeMasterFD() throws -> Int32 {
        state.lock()
        defer { state.unlock() }
        if case .closed = state.lifecycle { throw Error.closed }
        guard let spawned = state.spawned else { throw Error.notStarted }
        return spawned.masterFD
    }

    private func startReaderThread(fd: Int32, pid: pid_t) {
        let state = state
        let ioLock = ioLock
        let fdCloser = fdCloser
        let readerWillStart = readerWillStart
        let thread = Thread {
            readerWillStart?(fd)
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                Self.dispatchOutput(Data(buffer[0..<count]), state: state)
            }
            Self.closeMasterAfterReaderExit(
                fd: fd,
                pid: pid,
                state: state,
                ioLock: ioLock,
                fdCloser: fdCloser
            )
            Self.notifyExit(pid: pid, state: state, ioLock: ioLock)
        }
        thread.name = "NativePtySession.reader(\(pid))"

        state.lock()
        state.readerThread = thread
        state.unlock()

        thread.start()
    }

    private static func dispatchOutput(_ data: Data, state: State) {
        state.lock()
        let callback = state.writeToSurface
        state.unlock()

        if !data.isEmpty {
            callback?(data)
        }
    }

    private func notifySpawnFailure(_ error: Swift.Error) {
        state.lock()
        let callback = state.spawnFailed
        state.spawnFailed = nil
        state.unlock()

        callback?(error)
    }

    private static func notifyExit(pid: pid_t, state: State, ioLock: NSLock) {
        let status = reap(pid: pid)

        ioLock.lock()
        defer { ioLock.unlock() }

        state.lock()
        let callback = state.processExited
        state.processExited = nil
        state.unlock()

        callback?(pid, status)
    }

    private static func closeMasterAfterReaderExit(
        fd: Int32,
        pid: pid_t,
        state: State,
        ioLock: NSLock,
        fdCloser: FDCloser
    ) {
        ioLock.lock()
        defer { ioLock.unlock() }

        // The reader owns closing the master fd once it has been spawned.
        // `close()` only terminates the child; closing here avoids the race
        // where `close()` closes/reuses the fd before a just-created reader
        // thread has entered its read loop.
        state.lock()
        guard let current = state.spawned, current.masterFD == fd, current.pid == pid else {
            state.unlock()
            return
        }
        state.spawned = nil
        state.unlock()

        fdCloser(fd)
    }

    private func terminateAndClose(_ spawned: PtyProcess.Spawned) {
        closer(spawned)
    }

    private static func reap(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        for _ in 0..<10 {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == -1 { return nil }
            usleep(50_000)
        }
        return nil
    }

    private static func defaultTerminate(_ spawned: PtyProcess.Spawned) {
        _ = kill(spawned.pid, SIGTERM)
    }

    private static func exitCode(from status: Int32?) -> UInt32 {
        guard let status else { return 0 }
        let waitStatus = status & 0o177
        if waitStatus == 0 {
            return UInt32((status >> 8) & 0x000000ff)
        }
        if waitStatus != 0o177 {
            return UInt32(128 + waitStatus)
        }
        return 0
    }
}
