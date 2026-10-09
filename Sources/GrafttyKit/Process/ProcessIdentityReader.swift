#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Kernel-backed process identity used to distinguish a reused PID from
/// the long-running runtime process that originally registered presence.
public enum ProcessIdentityReader {
    public static func startTimeMicroseconds(ofPID pid: Int32) -> Int64? {
        #if os(Linux)
        guard let info = LinuxProcessStat.read(pid: pid) else { return nil }
        let ticks = sysconf(Int32(_SC_CLK_TCK))
        guard ticks > 0, info.startTicks <= UInt64(Int64.max / 1_000_000) else { return nil }
        guard let boot = linuxBootTimeSeconds else { return nil }
        return boot * 1_000_000 + Int64(info.startTicks) * 1_000_000 / Int64(ticks)
        #else
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
        }
        guard rc == size else { return nil }

        return microseconds(
            seconds: Int64(info.pbi_start_tvsec),
            microseconds: Int64(info.pbi_start_tvusec)
        )
        #endif
    }

    #if os(Linux)
    private static let linuxBootTimeSeconds: Int64? = {
        guard let text = try? String(contentsOfFile: "/proc/stat", encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("btime ") }) else { return nil }
        return Int64(line.dropFirst(6))
    }()
    #endif

    public static func microseconds(seconds: Int64, microseconds: Int64) -> Int64 {
        seconds * 1_000_000 + microseconds
    }
}
