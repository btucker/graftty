import Darwin
import Foundation

/// Kernel-backed process identity used to distinguish a reused PID from
/// the long-running runtime process that originally registered presence.
public enum ProcessIdentityReader {
    public static func startTimeMicroseconds(ofPID pid: Int32) -> Int64? {
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
    }

    public static func microseconds(seconds: Int64, microseconds: Int64) -> Int64 {
        seconds * 1_000_000 + microseconds
    }
}
