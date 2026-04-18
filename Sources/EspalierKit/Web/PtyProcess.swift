import Foundation
import Darwin

/// Swift's Darwin overlay marks `fork()` as `unavailable` with a message
/// steering callers toward `posix_spawn`. That's the right default advice,
/// but here we deliberately need a real `fork` so the child can `setsid`,
/// `ioctl(TIOCSCTTY)`, and become the controlling process of the PTY
/// before it `execve`s. Bind directly to the C symbol.
@_silgen_name("fork") private func _fork() -> pid_t

/// Open a PTY pair, fork, and exec a program with the PTY slave as
/// its controlling terminal and as fd 0/1/2. The parent retains the
/// master fd; the caller reads/writes it directly.
///
/// This is the narrow complement to Phase 1's `ZmxRunner`. `ZmxRunner`
/// is for short-lived subprocesses that communicate over pipes
/// (`kill`, `list`). `PtyProcess` is for long-lived subprocesses that
/// need a real TTY (`zmx attach`).
///
/// Not a class — the result struct carries everything needed to
/// interact with the child. The caller is responsible for closing
/// the master fd and reaping the child (`waitpid`).
public enum PtyProcess {

    public struct Spawned {
        public let masterFD: Int32
        public let pid: pid_t
    }

    public enum Error: Swift.Error {
        case openptFailed(errno: Int32)
        case grantptFailed(errno: Int32)
        case unlockptFailed(errno: Int32)
        case ptsnameFailed
        case forkFailed(errno: Int32)
        case execFailed(errno: Int32)
    }

    /// Spawn `argv[0]` with `argv[1...]` as arguments and `env` as
    /// the environment. The child's stdin/stdout/stderr are the PTY
    /// slave; the master fd is returned for the parent to use.
    public static func spawn(argv: [String], env: [String: String]) throws -> Spawned {
        precondition(!argv.isEmpty, "argv must not be empty")

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        if master < 0 { throw Error.openptFailed(errno: errno) }

        if grantpt(master) != 0 {
            let err = errno
            close(master)
            throw Error.grantptFailed(errno: err)
        }
        if unlockpt(master) != 0 {
            let err = errno
            close(master)
            throw Error.unlockptFailed(errno: err)
        }

        guard let slaveNameCStr = ptsname(master) else {
            close(master)
            throw Error.ptsnameFailed
        }
        let slavePath = String(cString: slaveNameCStr)

        // Keep the parent's slave fd open across fork. On macOS, when the
        // slave ref count crosses zero the PTY enters an EOF state on the
        // master, and subsequent reads return -1/EIO even after the child
        // opens a fresh slave fd. Holding one fd here until after fork
        // avoids that zero-crossing.
        let parentSlaveFD = Darwin.open(slavePath, O_RDWR | O_NOCTTY)
        if parentSlaveFD < 0 {
            close(master)
            throw Error.ptsnameFailed
        }

        // After fork the child inherits and execs; the C strings' lifetime
        // is owned by the parent until the child's execve replaces its
        // address space (or execve fails, in which case the child _exits).
        let argvCStrings = argv.map { strdup($0) }
        var argvPointers: [UnsafeMutablePointer<CChar>?] = argvCStrings + [nil]

        let mergedEnv = env.isEmpty ? ProcessInfo.processInfo.environment : env
        let envStrings = mergedEnv.map { "\($0)=\($1)" }
        let envCStrings = envStrings.map { strdup($0) }
        var envPointers: [UnsafeMutablePointer<CChar>?] = envCStrings + [nil]

        let pid = _fork()
        if pid < 0 {
            let err = errno
            close(parentSlaveFD)
            close(master)
            for ptr in argvCStrings { free(ptr) }
            for ptr in envCStrings { free(ptr) }
            throw Error.forkFailed(errno: err)
        }
        if pid == 0 {
            _ = setsid()
            let slave = Darwin.open(slavePath, O_RDWR)
            if slave < 0 { _exit(127) }
            // Non-fatal on some kernels; continue regardless of rc.
            _ = ioctl(slave, UInt(TIOCSCTTY), 0)
            _ = dup2(slave, 0)
            _ = dup2(slave, 1)
            _ = dup2(slave, 2)
            if slave > 2 { close(slave) }
            close(master)
            _ = argvPointers.withUnsafeMutableBufferPointer { argvBuf in
                envPointers.withUnsafeMutableBufferPointer { envBuf in
                    execve(argvBuf.baseAddress![0], argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            _exit(127)
        }

        close(parentSlaveFD)
        for ptr in argvCStrings { free(ptr) }
        for ptr in envCStrings { free(ptr) }
        return Spawned(masterFD: master, pid: pid)
    }

    /// Apply a terminal size change to the PTY. The shell on the slave
    /// side will receive SIGWINCH.
    public static func resize(masterFD: Int32, cols: UInt16, rows: UInt16) throws {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let rc = ioctl(masterFD, UInt(TIOCSWINSZ), &ws)
        if rc != 0 {
            throw Error.execFailed(errno: errno)  // repurposing; cleaner to add a dedicated case if this becomes common
        }
    }
}
