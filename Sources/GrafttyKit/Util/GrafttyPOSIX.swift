#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Qualified POSIX calls avoid collisions with instance methods such as close().
public enum GrafttyPOSIX {
    #if os(Linux)
    public static let streamSocket = Int32(SOCK_STREAM.rawValue)
    #else
    public static let streamSocket = SOCK_STREAM
    #endif

    static func ptySlavePath(_ masterFD: Int32) -> String? {
        #if os(Linux)
        // glibc ptsname() returns process-wide storage shared by concurrent spawns.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ptsname_r(masterFD, &buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
        #else
        guard let path = ptsname(masterFD) else { return nil }
        return String(cString: path)
        #endif
    }

    public static func peerUserID(_ fd: Int32) -> uid_t? {
        #if canImport(Darwin)
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(fd, &user, &group) == 0 ? user : nil
        #else
        // Linux SO_PEERCRED returns pid_t, uid_t, gid_t, each 32 bits.
        var credentials = [UInt32](repeating: 0, count: 3)
        var length = socklen_t(3 * MemoryLayout<UInt32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &credentials, &length) == 0,
              length == 12 else { return nil }
        return uid_t(credentials[1])
        #endif
    }

    /// Walk every component with O_NOFOLLOW, including intermediate directories.
    static func openBeneath(directoryFD: Int32, relativePath: String) -> Int32 {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            errno = EINVAL
            return -1
        }
        var directory = dup(directoryFD)
        guard directory >= 0 else { return -1 }
        defer { close(directory) }
        for component in parts.dropLast() {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard next >= 0 else { return -1 }
            close(directory)
            directory = next
        }
        return openat(directory, String(parts.last!), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    }

    public static func configureNoSigPipe(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #else
        // send() below applies MSG_NOSIGNAL to each write on Linux.
        return 0
        #endif
    }

    @discardableResult
    public static func close(_ fd: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.close(fd)
        #else
        return Glibc.close(fd)
        #endif
    }

    @discardableResult
    public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.read(fd, buffer, count)
        #else
        return Glibc.read(fd, buffer, count)
        #endif
    }

    @discardableResult
    public static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int {
        #if canImport(Darwin)
        return Darwin.write(fd, buffer, count)
        #else
        let sent = Glibc.send(fd, buffer, count, Int32(MSG_NOSIGNAL))
        if sent >= 0 || errno != ENOTSOCK { return sent }
        return Glibc.write(fd, buffer, count)
        #endif
    }

    @discardableResult
    public static func send(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        return Darwin.send(fd, buffer, count, flags)
        #else
        return Glibc.send(fd, buffer, count, flags | Int32(MSG_NOSIGNAL))
        #endif
    }

    @discardableResult
    public static func recv(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ flags: Int32) -> Int {
        #if canImport(Darwin)
        return Darwin.recv(fd, buffer, count, flags)
        #else
        return Glibc.recv(fd, buffer, count, flags)
        #endif
    }

    @discardableResult
    public static func socket(_ domain: Int32, _ type: Int32, _ protocolNumber: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.socket(domain, type, protocolNumber)
        #else
        return Glibc.socket(domain, type, protocolNumber)
        #endif
    }

    @discardableResult
    public static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.connect(fd, address, length)
        #else
        return Glibc.connect(fd, address, length)
        #endif
    }

    @discardableResult
    public static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>?, _ length: socklen_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.bind(fd, address, length)
        #else
        return Glibc.bind(fd, address, length)
        #endif
    }

    @discardableResult
    public static func accept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 {
        #if canImport(Darwin)
        return Darwin.accept(fd, address, length)
        #else
        return Glibc.accept(fd, address, length)
        #endif
    }

    @discardableResult
    public static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.listen(fd, backlog)
        #else
        return Glibc.listen(fd, backlog)
        #endif
    }

    @discardableResult
    public static func shutdown(_ fd: Int32, _ how: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.shutdown(fd, how)
        #else
        return Glibc.shutdown(fd, how)
        #endif
    }

    @discardableResult
    public static func open(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags)
        #else
        return Glibc.open(path, flags)
        #endif
    }

    @discardableResult
    public static func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.open(path, flags, mode)
        #else
        return Glibc.open(path, flags, mode)
        #endif
    }

    @discardableResult
    public static func unlink(_ path: UnsafePointer<CChar>) -> Int32 {
        #if canImport(Darwin)
        return Darwin.unlink(path)
        #else
        return Glibc.unlink(path)
        #endif
    }

    @discardableResult
    public static func realpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
        #if canImport(Darwin)
        return Darwin.realpath(path, resolved)
        #else
        return Glibc.realpath(path, resolved)
        #endif
    }

    @discardableResult
    public static func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 {
        #if canImport(Darwin)
        return Darwin.poll(fds, count, timeout)
        #else
        return Glibc.poll(fds, count, timeout)
        #endif
    }

    @discardableResult
    public static func lockf(_ fd: Int32, _ command: Int32, _ size: off_t) -> Int32 {
        #if canImport(Darwin)
        return Darwin.lockf(fd, command, size)
        #else
        return Glibc.lockf(fd, command, size)
        #endif
    }
}

#if os(Linux)
// glibc's X/Open PTY declarations are not exposed by Swift's default overlay.
@_silgen_name("posix_openpt") func posix_openpt(_ flags: Int32) -> Int32
@_silgen_name("grantpt") func grantpt(_ fd: Int32) -> Int32
@_silgen_name("unlockpt") func unlockpt(_ fd: Int32) -> Int32
@_silgen_name("ptsname_r") func ptsname_r(_ fd: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ count: Int) -> Int32
@_silgen_name("close_range") func linuxCloseRange(_ first: UInt32, _ last: UInt32, _ flags: Int32) -> Int32
#endif
