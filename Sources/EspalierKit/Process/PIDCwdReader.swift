import Foundation
import Darwin

/// `proc_pidinfo(PROC_PIDVNODEPATHINFO)` wrapper — reads another
/// process's cwd. Backs the shell-independent half of `PWD-1.3`.
public enum PIDCwdReader {

    /// Nil if the process is gone, unreadable, or its cdir has no
    /// path (e.g. running in a deleted directory).
    public static func cwd(ofPID pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let rc = withUnsafeMutablePointer(to: &info) { ptr -> Int32 in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard rc == size else { return nil }

        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                let value = String(cString: cStr)
                return value.isEmpty ? nil : value
            }
        }
    }
}
