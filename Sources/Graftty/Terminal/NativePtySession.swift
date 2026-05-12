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

    enum Error: Swift.Error {
        case alreadyStarted
        case closed
        case notStarted
        case spawnFailed(Swift.Error)
    }

    private let argv: [String]
    private let env: [String: String]
    private let workingDirectory: URL?
    private let initialSize: (cols: UInt16, rows: UInt16)?
    private let spawner: Spawner
    private let writer: Writer
    private let stateLock = NSLock()
    private let writeLock = NSLock()

    private var spawned: PtyProcess.Spawned?
    private var readerThread: Thread?
    private var isClosed = false
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
        writer: @escaping Writer = SocketIO.writeAll
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
        guard !isClosed else {
            stateLock.unlock()
            throw Error.closed
        }
        guard spawned == nil else {
            stateLock.unlock()
            throw Error.alreadyStarted
        }
        stateLock.unlock()

        let newSpawn: PtyProcess.Spawned
        do {
            newSpawn = try spawner(argv, env, workingDirectory, initialSize)
        } catch {
            notifySpawnFailure(error)
            throw Error.spawnFailed(error)
        }

        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            terminateAndClose(newSpawn)
            throw Error.closed
        }
        spawned = newSpawn
        stateLock.unlock()

        startReaderThread(fd: newSpawn.masterFD, pid: newSpawn.pid)
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }

        let fd = try activeMasterFD()
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            try writer(fd, base, buffer.count)
        }
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        try PtyProcess.resize(masterFD: activeMasterFD(), cols: cols, rows: rows)
    }

    func close() {
        stateLock.lock()
        if isClosed {
            stateLock.unlock()
            return
        }
        isClosed = true
        let currentSpawn = spawned
        spawned = nil
        writeToSurface = nil
        processExited = nil
        spawnFailed = nil
        stateLock.unlock()

        if let currentSpawn {
            terminateAndClose(currentSpawn)
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
        guard !isClosed else { throw Error.closed }
        guard let spawned else { throw Error.notStarted }
        return spawned.masterFD
    }

    private func startReaderThread(fd: Int32, pid: pid_t) {
        let thread = Thread { [weak self] in
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
        stateLock.lock()
        guard let current = spawned, current.masterFD == fd, current.pid == pid else {
            stateLock.unlock()
            return
        }
        spawned = nil
        stateLock.unlock()

        Darwin.close(fd)
    }

    private func terminateAndClose(_ spawned: PtyProcess.Spawned) {
        _ = kill(spawned.pid, SIGTERM)
        Darwin.close(spawned.masterFD)
        _ = reap(pid: spawned.pid)
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
