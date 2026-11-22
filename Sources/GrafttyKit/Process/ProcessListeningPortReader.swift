#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// Kernel-backed list of the TCP ports one process is listening on. Used to
/// find a provider's local server when the provider exposes no way to choose
/// or report its port.
public enum ProcessListeningPortReader {
    public static func listeningTCPPorts(ofPID pid: pid_t) -> [Int] {
        #if os(Linux)
        let descriptors = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(pid)/fd")) ?? []
        let inodes = Set(descriptors.compactMap { descriptor -> String? in
            guard let target = try? FileManager.default.destinationOfSymbolicLink(
                atPath: "/proc/\(pid)/fd/\(descriptor)"
            ), target.hasPrefix("socket:["), target.hasSuffix("]") else { return nil }
            return String(target.dropFirst("socket:[".count).dropLast())
        })
        guard !inodes.isEmpty else { return [] }
        let tables = ["/proc/net/tcp", "/proc/net/tcp6"].compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        return listeningPorts(inProcNetTCP: tables.joined(separator: "\n"), socketInodes: inodes)
        #else
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        // Descriptors can open between the sizing call and the listing call.
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = descriptors.withUnsafeMutableBytes { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
        }
        guard used > 0 else { return [] }
        var ports: Set<Int> = []
        for descriptor in descriptors.prefix(Int(used) / stride)
        where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            let read = withUnsafeMutablePointer(to: &info) {
                proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, $0, size)
            }
            guard read == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP),
                  info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            // The kernel reports the port in network byte order in the low 16 bits.
            let port = UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport).bigEndian
            if port > 0 { ports.insert(Int(port)) }
        }
        return ports.sorted()
        #endif
    }

    /// Ports of the `LISTEN` rows in `/proc/net/tcp{,6}` text whose socket
    /// inode belongs to `socketInodes`.
    static func listeningPorts(inProcNetTCP table: String, socketInodes: Set<String>) -> [Int] {
        var ports: Set<Int> = []
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            // sl local_address rem_address st tx_queue rx_queue tr:tm->when retrnsmt uid timeout inode
            guard fields.count > 9, fields[3] == "0A", socketInodes.contains(String(fields[9])),
                  let portText = fields[1].split(separator: ":").last,
                  let port = Int(portText, radix: 16), port > 0 else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }
}
