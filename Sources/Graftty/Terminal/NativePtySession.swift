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
    private let stateLock = NSLock()
    private let ioLock = NSLock()

    private var lifecycle: Lifecycle = .idle
    private var spawned: PtyProcess.Spawned?
    private var readerThread: Thread?
    private var didNotifyExit = false
    private var didNotifySpawnFailure = false
    private var writeToSurface: ((Data) -> Void)?
    private var processExited: ((pid_t, Int32?) -> Void)?
    private var spawnFailed: ((Swift.Error) -> Void)?

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
        self.writeToSurface = writeToSurface
        self.processExited = processExited
        self.spawnFailed = spawnFailed
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
        stateLock.lock()
        switch lifecycle {
        case .closed:
            stateLock.unlock()
            throw Error.closed
        case .idle:
            lifecycle = .starting
            stateLock.unlock()
        case .failed(let error):
            stateLock.unlock()
            throw Error.spawnFailed(error)
        case .starting, .running:
            stateLock.unlock()
            throw Error.alreadyStarted
        }

        let newSpawn: PtyProcess.Spawned
        do {
            newSpawn = try spawner(argv, env, workingDirectory, initialSize)
        } catch {
            stateLock.lock()
            if case .starting = lifecycle { lifecycle = .failed(error) }
            stateLock.unlock()
            notifySpawnFailure(error)
            throw Error.spawnFailed(error)
        }

        stateLock.lock()
        if case .closed = lifecycle {
            stateLock.unlock()
            closer(newSpawn)
            fdCloser(newSpawn.masterFD)
            throw Error.closed
        }
        spawned = newSpawn
        lifecycle = .running
        stateLock.unlock()

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
        stateLock.lock()
        if case .closed = lifecycle {
            stateLock.unlock()
            return
        }
        lifecycle = .closed
        let currentSpawn = spawned
        writeToSurface = nil
        processExited = nil
        spawnFailed = nil
        stateLock.unlock()

        if let currentSpawn {
            ioLock.lock()
            terminateAndClose(currentSpawn)
            ioLock.unlock()
        }
    }

    var activeMasterFDForTesting: Int32? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return spawned?.masterFD
    }

    private func activeMasterFD() throws -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        if case .closed = lifecycle { throw Error.closed }
        guard let spawned else { throw Error.notStarted }
        return spawned.masterFD
    }

    private func startReaderThread(fd: Int32, pid: pid_t) {
        let thread = Thread { [weak self] in
            self?.readerWillStart?(fd)
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = buffer.withUnsafeMutableBufferPointer {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                self?.dispatchOutput(Data(buffer[0..<count]))
            }
            self?.closeMasterAfterReaderExit(fd: fd, pid: pid)
            self?.notifyExit(pid: pid)
        }
        thread.name = "NativePtySession.reader(\(pid))"

        stateLock.lock()
        readerThread = thread
        stateLock.unlock()

        thread.start()
    }

    private func dispatchOutput(_ data: Data) {
        stateLock.lock()
        let callback = writeToSurface
        stateLock.unlock()

        if !data.isEmpty {
            callback?(data)
        }
    }

    private func notifySpawnFailure(_ error: Swift.Error) {
        stateLock.lock()
        guard !didNotifySpawnFailure else {
            stateLock.unlock()
            return
        }
        didNotifySpawnFailure = true
        let callback = spawnFailed
        spawnFailed = nil
        stateLock.unlock()

        callback?(error)
    }

    private func notifyExit(pid: pid_t) {
        let status = reap(pid: pid)

        stateLock.lock()
        guard !didNotifyExit else {
            stateLock.unlock()
            return
        }
        didNotifyExit = true
        let callback = processExited
        processExited = nil
        stateLock.unlock()

        callback?(pid, status)
    }

    private func closeMasterAfterReaderExit(fd: Int32, pid: pid_t) {
        ioLock.lock()
        defer { ioLock.unlock() }

        // The reader owns closing the master fd once it has been spawned.
        // `close()` only terminates the child; closing here avoids the race
        // where `close()` closes/reuses the fd before a just-created reader
        // thread has entered its read loop.
        stateLock.lock()
        guard let current = spawned, current.masterFD == fd, current.pid == pid else {
            stateLock.unlock()
            return
        }
        spawned = nil
        stateLock.unlock()

        fdCloser(fd)
    }

    private func terminateAndClose(_ spawned: PtyProcess.Spawned) {
        closer(spawned)
    }

    private func reap(pid: pid_t) -> Int32? {
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
        var status: Int32 = 0
        for _ in 0..<10 {
            if waitpid(spawned.pid, &status, WNOHANG) != 0 { break }
            usleep(50_000)
        }
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
