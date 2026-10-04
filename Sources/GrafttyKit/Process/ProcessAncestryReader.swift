import Darwin
import Foundation

/// Kernel-backed parent and controlling-terminal lookup for one process,
/// used to walk from a tool shell with no tty up to the pane that owns it.
public enum ProcessAncestryReader {
    public struct Entry: Equatable {
        public let parentPID: pid_t
        /// `/dev/ttysNNN` when the process has a controlling terminal.
        public let ttyPath: String?

        public init(parentPID: pid_t, ttyPath: String?) {
            self.parentPID = parentPID
            self.ttyPath = ttyPath
        }
    }

    public static func entry(forPID pid: pid_t) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, size)
        }
        guard rc == size else { return nil }
        var ttyPath: String?
        // e_tdev is NODEV (all bits set) when there is no controlling tty.
        if info.e_tdev != UInt32.max,
           let name = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR)) {
            ttyPath = "/dev/" + String(cString: name)
        }
        return Entry(parentPID: pid_t(info.pbi_ppid), ttyPath: ttyPath)
    }
}
