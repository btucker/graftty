import Foundation
import Darwin

/// Sync subprocess wrapper for invoking `zmx` (or any other executable
/// with explicit env). Three flavors mirror `GitRunner`:
///
/// - `run` — throws on non-zero exit; returns stdout
/// - `capture` — returns (stdout, exitCode) without throwing
/// - `captureAll` — returns (stdout, stderr, exitCode) for diagnostics
///
/// Differs from `GitRunner` in two ways: the executable URL is a
/// parameter (not a hardcoded path), and env is explicit (the caller
/// passes exactly what the child should see — empty dict means an
/// almost-empty env, not "inherit").
public enum ZmxRunner {

    private static let maximumDrainBytesPerPass = 64 * 1024

    public enum Error: Swift.Error, Equatable {
        case zmxFailed(terminationStatus: Int32)
        case timedOut
    }

    /// Throws on non-zero exit. Use when nonzero means "the call failed".
    public static func run(
        executable: URL,
        args: [String],
        env: [String: String],
        timeout: TimeInterval? = nil
    ) throws -> String {
        let result = try capture(executable: executable, args: args, env: env, timeout: timeout)
        guard result.exitCode == 0 else {
            throw Error.zmxFailed(terminationStatus: result.exitCode)
        }
        return result.stdout
    }

    /// Returns (stdout, exitCode). Use when the exit code is diagnostic
    /// (e.g., `zmx kill` of a session that already died — nonzero is fine).
    public static func capture(
        executable: URL,
        args: [String],
        env: [String: String],
        timeout: TimeInterval? = nil
    ) throws -> (stdout: String, exitCode: Int32) {
        let result = try spawnAndCapture(
            executable: executable,
            args: args,
            env: env,
            captureStderr: false,
            timeout: timeout
        )
        return (stdout: result.stdout, exitCode: result.exitCode)
    }

    /// Returns (stdout, stderr, exitCode). Use when stderr carries the
    /// user-visible error on failure. Both pipes are read; safe for
    /// bounded-output commands. Don't use for chatty long-running output.
    public static func captureAll(
        executable: URL,
        args: [String],
        env: [String: String],
        timeout: TimeInterval? = nil
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        try spawnAndCapture(
            executable: executable,
            args: args,
            env: env,
            captureStderr: true,
            timeout: timeout
        )
    }

    private static func spawnAndCapture(
        executable: URL,
        args: [String],
        env: [String: String],
        captureStderr: Bool,
        timeout: TimeInterval?
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        var stdoutFD: [Int32] = [0, 0]
        guard pipe(&stdoutFD) == 0 else { throw posixError(errno) }
        var stdoutRead = stdoutFD[0]
        var stdoutWrite = stdoutFD[1]
        defer { closeIfOpen(&stdoutRead) }
        defer { closeIfOpen(&stdoutWrite) }

        var stderrRead: Int32 = -1
        var stderrWrite: Int32 = -1
        if captureStderr {
            var stderrFD: [Int32] = [0, 0]
            guard pipe(&stderrFD) == 0 else { throw posixError(errno) }
            stderrRead = stderrFD[0]
            stderrWrite = stderrFD[1]
        }
        defer { closeIfOpen(&stderrRead) }
        defer { closeIfOpen(&stderrWrite) }

        var actions: posix_spawn_file_actions_t?
        var rc = posix_spawn_file_actions_init(&actions)
        guard rc == 0 else { throw posixError(rc) }
        defer { posix_spawn_file_actions_destroy(&actions) }

        rc = posix_spawn_file_actions_adddup2(&actions, stdoutWrite, STDOUT_FILENO)
        guard rc == 0 else { throw posixError(rc) }
        rc = posix_spawn_file_actions_addclose(&actions, stdoutRead)
        guard rc == 0 else { throw posixError(rc) }
        rc = posix_spawn_file_actions_addclose(&actions, stdoutWrite)
        guard rc == 0 else { throw posixError(rc) }

        if captureStderr {
            rc = posix_spawn_file_actions_adddup2(&actions, stderrWrite, STDERR_FILENO)
            guard rc == 0 else { throw posixError(rc) }
            rc = posix_spawn_file_actions_addclose(&actions, stderrRead)
            guard rc == 0 else { throw posixError(rc) }
            rc = posix_spawn_file_actions_addclose(&actions, stderrWrite)
            guard rc == 0 else { throw posixError(rc) }
        } else {
            rc = "/dev/null".withCString {
                posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, $0, O_WRONLY, 0)
            }
            guard rc == 0 else { throw posixError(rc) }
        }

        var attrs: posix_spawnattr_t?
        rc = posix_spawnattr_init(&attrs)
        guard rc == 0 else { throw posixError(rc) }
        defer { posix_spawnattr_destroy(&attrs) }
        rc = posix_spawnattr_setpgroup(&attrs, 0)
        guard rc == 0 else { throw posixError(rc) }
        rc = posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETPGROUP))
        guard rc == 0 else { throw posixError(rc) }

        let argvStrings = [executable.path] + args
        let argvCStrings = argvStrings.map { strdup($0) }
        var argvPointers: [UnsafeMutablePointer<CChar>?] = argvCStrings + [nil]
        defer { argvCStrings.forEach { free($0) } }

        let envStrings = env.map { "\($0)=\($1)" }
        let envCStrings = envStrings.map { strdup($0) }
        var envPointers: [UnsafeMutablePointer<CChar>?] = envCStrings + [nil]
        defer { envCStrings.forEach { free($0) } }

        var pid: pid_t = 0
        rc = executable.path.withCString { path in
            argvPointers.withUnsafeMutableBufferPointer { argvBuffer in
                envPointers.withUnsafeMutableBufferPointer { envBuffer in
                    posix_spawn(
                        &pid,
                        path,
                        &actions,
                        &attrs,
                        argvBuffer.baseAddress,
                        envBuffer.baseAddress
                    )
                }
            }
        }
        guard rc == 0 else { throw posixError(rc) }

        closeIfOpen(&stdoutWrite)
        closeIfOpen(&stderrWrite)

        let result = try captureUntilExit(
            pid: pid,
            stdoutFD: stdoutRead,
            stderrFD: captureStderr ? stderrRead : nil,
            timeout: timeout
        )
        return (
            stdout: String(data: result.stdout, encoding: .utf8) ?? "",
            stderr: String(data: result.stderr, encoding: .utf8) ?? "",
            exitCode: result.exitCode
        )
    }

    private static func captureUntilExit(
        pid: pid_t,
        stdoutFD: Int32,
        stderrFD: Int32?,
        timeout: TimeInterval?
    ) throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        setNonBlocking(stdoutFD)
        if let stderrFD {
            setNonBlocking(stderrFD)
        }

        var stdout = Data()
        var stderr = Data()
        var stdoutOpen = true
        var stderrOpen = stderrFD != nil
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        while true {
            if stdoutOpen {
                stdoutOpen = drainAvailable(from: stdoutFD, into: &stdout)
            }
            if stderrOpen, let stderrFD {
                stderrOpen = drainAvailable(from: stderrFD, into: &stderr)
            }

            if let exitCode = pollChild(pid) {
                if stdoutOpen {
                    _ = drainAvailable(from: stdoutFD, into: &stdout)
                }
                if stderrOpen, let stderrFD {
                    _ = drainAvailable(from: stderrFD, into: &stderr)
                }
                return (stdout: stdout, stderr: stderr, exitCode: exitCode)
            }

            if let deadline, Date() >= deadline {
                terminateTimedOutChild(pid)
                throw Error.timedOut
            }

            var descriptors = [
                pollfd(
                    fd: stdoutOpen ? stdoutFD : -1,
                    events: Int16(POLLIN | POLLHUP),
                    revents: 0
                ),
            ]
            if let stderrFD {
                descriptors.append(
                    pollfd(
                        fd: stderrOpen ? stderrFD : -1,
                        events: Int16(POLLIN | POLLHUP),
                        revents: 0
                    )
                )
            }

            descriptors.withUnsafeMutableBufferPointer { buffer in
                _ = Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), 20)
            }
        }
    }

    private static func terminateTimedOutChild(_ pid: pid_t) {
        killpg(pid, SIGTERM)
        let termDeadline = Date().addingTimeInterval(0.2)
        var childExited = false
        while Date() < termDeadline {
            if pollChild(pid) != nil {
                childExited = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        killpg(pid, SIGKILL)
        if !childExited {
            _ = waitForChild(pid)
        }
    }

    private static func pollChild(_ pid: pid_t) -> Int32? {
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        guard waited == pid else { return nil }
        return exitCode(fromWaitStatus: status)
    }

    private static func waitForChild(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        return exitCode(fromWaitStatus: status)
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 {
            return (status >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// Drains up to `maximumDrainBytesPerPass` currently-readable bytes.
    /// The per-pass bound ensures a busy stream cannot starve the other
    /// stream, child-exit polling, or timeout enforcement.
    /// Returns `true` while the writer may produce more data, and `false`
    /// after EOF or an unrecoverable read error.
    private static func drainAvailable(from fd: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var drainedBytes = 0
        while drainedBytes < maximumDrainBytesPerPass {
            let bytesToRead = min(buffer.count, maximumDrainBytesPerPass - drainedBytes)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fd, $0.baseAddress, bytesToRead)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(Int(count)))
                drainedBytes += Int(count)
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                return true
            } else {
                return false
            }
        }
        return true
    }

    private static func closeIfOpen(_ fd: inout Int32) {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    private static func posixError(_ code: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
