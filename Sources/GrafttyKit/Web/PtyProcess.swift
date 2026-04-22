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
    ///
    /// `initialSize` (optional) applies a starting winsize to the PTY
    /// *before* the child execs, so the child's first `TIOCGWINSZ`
    /// read sees it. `zmx attach` uses that initial size to populate
    /// its `Init` IPC; if callers want deterministic startup sizing
    /// (tests, or propagating the host-side known viewport), pass it
    /// here rather than race an initial TIOCSWINSZ against the child's
    /// startup path. On macOS the ioctl is applied after the parent
    /// has opened the slave — winsize storage is slave-backed and
    /// returns ENOTTY until at least one slave open has occurred.
    public static func spawn(
        argv: [String],
        env: [String: String],
        initialSize: (cols: UInt16, rows: UInt16)? = nil
    ) throws -> Spawned {
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

        if let size = initialSize {
            var ws = winsize(
                ws_row: size.rows,
                ws_col: size.cols,
                ws_xpixel: 0,
                ws_ypixel: 0
            )
            _ = ioctl(master, UInt(TIOCSWINSZ), &ws)
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
            // Close every OTHER inherited fd before execve. Without this,
            // any parent-opened file or socket without FD_CLOEXEC leaks
            // into the zmx child, which still holds them after Graftty
            // quits. Observed live: the `WebServer` listen socket leaked
            // into zmx-attach children, so after Graftty died the port
            // stayed bound to an orphan zmx process and the next Graftty
            // launch couldn't rebind.
            //
            // `getdtablesize()` returns the per-process fd table ceiling
            // (currently open OR available) — NOT `RLIMIT_NOFILE.rlim_cur`
            // which can be `RLIM_INFINITY` (effectively Int32.max → 2-billion
            // close() calls, which hung our tests indefinitely on the first
            // attempt). The dtable size is typically ≤10k, closing 3..that
            // is a few ms of syscalls.
            let maxFd = getdtablesize()
            var fd: Int32 = 3
            while fd < maxFd {
                close(fd)
                fd += 1
            }
            // Exec via posix_spawn with SETSIGMASK (empty mask) rather
            // than plain execve. fork(2) preserves the parent sigmask
            // and execve carries it into the new image; the Swift
            // runtime blocks a family of signals on its GCD service
            // threads, so a child inheriting that mask starts with
            // SIGWINCH blocked and zmx's resize handler never fires.
            // SETEXEC makes posix_spawn replace the current image
            // rather than fork+exec, so we keep the setsid/TIOCSCTTY
            // setup done above (neither is expressible via spawnattr).
            var spawnAttrs: posix_spawnattr_t?
            guard posix_spawnattr_init(&spawnAttrs) == 0 else { _exit(127) }

            var emptyMask = sigset_t()
            sigemptyset(&emptyMask)
            _ = posix_spawnattr_setsigmask(&spawnAttrs, &emptyMask)
            _ = posix_spawnattr_setflags(
                &spawnAttrs,
                Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK)
            )

            var spawnedPid: pid_t = 0
            _ = argvPointers.withUnsafeMutableBufferPointer { argvBuf in
                envPointers.withUnsafeMutableBufferPointer { envBuf in
                    posix_spawn(
                        &spawnedPid,
                        argvBuf.baseAddress![0],
                        nil,
                        &spawnAttrs,
                        argvBuf.baseAddress,
                        envBuf.baseAddress
                    )
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

    /// Read the PTY's current winsize. Used by the server to announce
    /// grid changes to attached web/iOS clients so they can size their
    /// rendering to match. Returns nil when the ioctl fails (typically
    /// means the fd is closed).
    public static func currentSize(masterFD: Int32) -> (cols: UInt16, rows: UInt16)? {
        var ws = winsize()
        let rc = ioctl(masterFD, UInt(TIOCGWINSZ), &ws)
        if rc != 0 { return nil }
        return (cols: ws.ws_col, rows: ws.ws_row)
    }
}
