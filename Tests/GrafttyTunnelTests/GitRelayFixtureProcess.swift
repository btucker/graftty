import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Match the dispatch-backed blocking fixtures in ManualSubprocessScheduler.
// Task.detached still uses Swift's cooperative pool.
func relayFixtureIO<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(with: Result { try operation() })
        }
    }
}

/// Test-only process-group owner. Keep the leader unreaped until group cleanup
/// so cancellation cannot signal a PID that the kernel has already reused.
final class GitRelayFixtureProcess: @unchecked Sendable {
    let output = Pipe()
    let input: Pipe?
    private let arguments: [String]
    private let environment: [String: String]
    private let lock = NSLock()
    private var child: pid_t?
    private var status: Int32?
    private var stopped = false

    init(_ arguments: [String], root: URL, duplex: Bool = false) {
        self.arguments = arguments
        environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin", "HOME": root.path,
                       "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        input = duplex ? Pipe() : nil
    }

    var processID: pid_t? { lock.withLock { child } }

    // Call on a dispatch worker. Launch and registration share the stop lock.
    func start() throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            #if os(Linux)
            var actions = posix_spawn_file_actions_t()
            var attributes = posix_spawnattr_t()
            #else
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            #endif
            try checked(posix_spawn_file_actions_init(&actions))
            defer { posix_spawn_file_actions_destroy(&actions) }
            try checked(posix_spawnattr_init(&attributes))
            defer { posix_spawnattr_destroy(&attributes) }
            if let input {
                try checked(posix_spawn_file_actions_adddup2(&actions, input.fileHandleForReading.fileDescriptor, STDIN_FILENO))
            } else {
                try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            }
            try checked(posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
            try checked(posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0))
            // Do not leak another concurrently launched fixture's pipe ends.
            #if os(Linux)
            try checked(posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1))
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
            #else
            let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT
            #endif
            try checked(posix_spawnattr_setpgroup(&attributes, 0))
            var signals = sigset_t()
            sigemptyset(&signals)
            try checked(posix_spawnattr_setsigmask(&attributes, &signals))
            sigfillset(&signals)
            try checked(posix_spawnattr_setsigdefault(&attributes, &signals))
            try checked(posix_spawnattr_setflags(&attributes, Int16(flags)))
            let strings = (["/usr/bin/env"] + arguments).map { strdup($0) }
            let variables = environment.map { strdup("\($0.key)=\($0.value)") }
            defer {
                strings.forEach { free($0) }
                variables.forEach { free($0) }
            }
            var argv = strings + [nil], envp = variables + [nil]
            var pid: pid_t = 0
            let result = argv.withUnsafeMutableBufferPointer { argv in
                envp.withUnsafeMutableBufferPointer { envp in
                    posix_spawn(&pid, "/usr/bin/env", &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
                }
            }
            try checked(result)
            child = pid
            try? output.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
        }
    }

    // Only signals here. The I/O worker closes its own read handle after EOF;
    // closing a FileHandle concurrently with a blocked Foundation read can wait.
    func stop() {
        lock.withLock {
            stopped = true
            if let child, status == nil { _ = killpg(child, SIGKILL) }
        }
    }

    // Call after closing NIO's duplicate descriptors, and on a dispatch worker.
    @discardableResult
    func wait() throws -> Int32 {
        let state = lock.withLock { (child, status) }
        if let status = state.1 { return status }
        guard let pid = state.0 else {
            lock.withLock { closeHandles() }
            return 0
        }
        var information = siginfo_t()
        var result: Int32
        repeat { result = waitid(P_PID, id_t(pid), &information, WEXITED | WNOWAIT) } while result < 0 && errno == EINTR
        return try lock.withLock {
            if let status { return status }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // The leader is still ours. Stop descendants before releasing it.
            _ = killpg(pid, SIGKILL)
            closeHandles()
            var raw: Int32 = 0
            var reaped: pid_t
            repeat { reaped = waitpid(pid, &raw, 0) } while reaped < 0 && errno == EINTR
            guard reaped == pid else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let code = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
            status = code
            return code
        }
    }

    func relayDescriptors() throws -> (Int32, Int32) {
        guard let input else { throw POSIXError(.EBADF) }
        let reader = fcntl(output.fileHandleForReading.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard reader >= 0 else { throw POSIXError(.EBADF) }
        let writer = fcntl(input.fileHandleForWriting.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard writer >= 0 else { close(reader); throw POSIXError(.EBADF) }
        try? output.fileHandleForReading.close()
        try? input.fileHandleForWriting.close()
        return (reader, writer)
    }

    func result() async throws -> Data {
        do {
            let data = try await withTaskCancellationHandler {
                try await relayFixtureIO { [self] in
                    do {
                        try start()
                        let data = try output.fileHandleForReading.readToEnd() ?? Data()
                        let status = try wait()
                        guard status == 0 else { throw GitRelayFixtureFailure.exit(status, arguments.first ?? "fixture") }
                        return data
                    } catch {
                        stop()
                        _ = try? wait()
                        throw error
                    }
                }
            } onCancel: {
                DispatchQueue.global().async { self.stop() }
            }
            try Task.checkCancellation()
            return data
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private func closeHandles() {
        try? input?.fileHandleForReading.close()
        try? input?.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
    }

    private func checked(_ result: Int32) throws {
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    }
}

enum GitRelayFixtureFailure: Error, Equatable { case exit(Int32, String) }
