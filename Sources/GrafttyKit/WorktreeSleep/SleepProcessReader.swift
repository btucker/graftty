import Darwin
import Foundation

/// Reads kernel counters and stable identity. CPU values returned by
/// proc_pid_rusage are nanoseconds; disk counters cover reads and writes.
public enum SleepProcessReader {
    public static func sample(pid: Int32) -> SleepProcessSample? {
        guard pid > 1 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size,
              bsd.pbi_uid == getuid() else { return nil }
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        let identity = SleepProcessIdentity(pid: pid, startTime: ProcessIdentityReader.microseconds(
            seconds: Int64(bsd.pbi_start_tvsec), microseconds: Int64(bsd.pbi_start_tvusec)))
        guard result == 0, ProcessIdentityReader.startTimeMicroseconds(ofPID: pid) == identity.startTime else { return nil }
        return SleepProcessSample(identity: identity, cpuNanoseconds: usage.ri_user_time &+ usage.ri_system_time,
                                  diskBytes: usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten,
                                  isStopped: bsd.pbi_status == UInt32(SSTOP))
    }

    public static func signal(_ identity: SleepProcessIdentity, stop: Bool) -> Bool {
        guard identity.pid != getpid(), let current = sample(pid: identity.pid), current.identity == identity,
              !stop || !current.isStopped else { return false }
        return kill(identity.pid, stop ? SIGSTOP : SIGCONT) == 0
    }

    public static func executable(pid: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return String(cString: bytes)
    }

    /// The socket's kernel peer PID must be the root's direct parent.
    /// This binds an old zmx log PID to the actual session daemon instead
    /// of trusting a log or a cached PID after reuse.
    public static func ownedShell(pid: Int32, sessionSocket: URL, zmxExecutable: URL) -> Bool {
        guard let ancestry = ProcessAncestryReader.entry(forPID: pid),
              executable(pid: ancestry.parentPID) == zmxExecutable.resolvingSymlinksInPath().path,
              let shell = executable(pid: pid),
              supportedShells.contains(shell),
              let peer = peerPID(socketURL: sessionSocket), peer == ancestry.parentPID,
              let tty = ancestry.ttyPath else { return false }
        let ttyFD = open(tty, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard ttyFD >= 0 else { return false }
        defer { close(ttyFD) }
        // Only a foreground shell prompt is a candidate. A foreground job
        // with a quiet parent cannot become eligible merely by using no CPU.
        return tcgetpgrp(ttyFD) == getpgid(pid)
    }

    private static let supportedShells: Set<String> = {
        let configured = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        return Set(configured.split(separator: "\n").map(String.init).filter { $0.hasPrefix("/") })
    }()

    private static func peerPID(socketURL: URL) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(socketURL.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        guard withUnsafePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }) == 0 else { return nil }
        var pid: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, 0, LOCAL_PEERPID, &pid, &length) == 0 else { return nil }
        return pid
    }
}
