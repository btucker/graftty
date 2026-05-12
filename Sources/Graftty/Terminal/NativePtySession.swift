import Darwin
import Foundation
import GrafttyKit

final class NativePtySession {
    typealias Spawner = (
        _ argv: [String],
        _ env: [String: String],
        _ currentDirectory: URL?,
        _ initialSize: (cols: UInt16, rows: UInt16)?
    ) throws -> PtyProcess.Spawned

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
    private let stateLock = NSLock()

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
        }
    ) {
        self.argv = argv
        self.env = env
        self.workingDirectory = workingDirectory
        self.initialSize = initialSize
        self.writeToSurface = writeToSurface
        self.processExited = processExited
        self.spawnFailed = spawnFailed
        self.spawner = spawner
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
        let fd = try activeMasterFD()
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            try SocketIO.writeAll(
                fd: fd,
                bytes: base.assumingMemoryBound(to: UInt8.self),
                count: buffer.count
            )
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
}
