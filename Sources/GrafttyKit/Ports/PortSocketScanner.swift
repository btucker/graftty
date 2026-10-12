import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Platform socket enumeration; the shared PortScanner owns pane attribution,
/// process-tree traversal, polling, and snapshot deduplication.
public protocol PortSocketScanning: Sendable {
    func listeningSockets(pids: Set<pid_t>) async -> [LsofOutputParser.Row]?
}

public struct LsofPortSocketScanner: PortSocketScanning {
    let runner: any LsofRunner
    public init(runner: any LsofRunner = SystemLsofRunner()) { self.runner = runner }
    public func listeningSockets(pids: Set<pid_t>) async -> [LsofOutputParser.Row]? {
        guard let output = await runner.run(pids: pids.sorted().map(String.init).joined(separator: ",")) else { return nil }
        return LsofOutputParser.parse(output)
    }
}

public struct LinuxProcSocketScanner: PortSocketScanning {
    let procRoot: URL
    public init(procRoot: URL = URL(fileURLWithPath: "/proc")) { self.procRoot = procRoot }
    public func listeningSockets(pids: Set<pid_t>) async -> [LsofOutputParser.Row]? {
        // Procfs reads can block independently of the main actor or scanner actor.
        await Task.detached(priority: .utility) { scan(pids: pids) }.value
    }

    private func scan(pids: Set<pid_t>) -> [LsofOutputParser.Row]? {
        var owners: [UInt64: [(pid_t, String)]] = [:]
        for pid in pids where pid > 0 {
            let process = procRoot.appendingPathComponent(String(pid))
            guard let descriptors = try? FileManager.default.contentsOfDirectory(atPath: process.appendingPathComponent("fd").path),
                  let name = try? String(contentsOf: process.appendingPathComponent("comm"), encoding: .utf8) else { continue }
            var inodes: Set<UInt64> = []
            for descriptor in descriptors {
                guard let link = try? FileManager.default.destinationOfSymbolicLink(atPath: process.appendingPathComponent("fd/" + descriptor).path),
                      link.hasPrefix("socket:["), link.hasSuffix("]"),
                      let inode = UInt64(link.dropFirst(8).dropLast()) else { continue }
                inodes.insert(inode)
            }
            for inode in inodes { owners[inode, default: []].append((pid, name.trimmingCharacters(in: .newlines))) }
        }
        guard !owners.isEmpty else { return [] }
        var result: [LsofOutputParser.Row] = []
        var readable = false
        // Use this host's network namespace; sockets in nested namespaces are
        // not reachable through the host loopback tunnel.
        for table in ["tcp", "tcp6"] {
            guard let text = try? String(contentsOf: procRoot.appendingPathComponent("net/" + table), encoding: .utf8) else { continue }
            readable = true
            for line in text.split(separator: "\n") {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count > 9, fields[3] == "0A", let inode = UInt64(fields[9]),
                      let processes = owners[inode] else { continue }
                let local = fields[1].split(separator: ":")
                guard local.count == 2, let port = UInt16(local[1], radix: 16), port > 0,
                      let address = Self.address(String(local[0]), ipv6: table == "tcp6") else { continue }
                for (pid, name) in processes { result.append(.init(processName: name, pid: pid, address: address, port: port)) }
            }
        }
        return readable ? result : nil
    }

    private static func address(_ text: String, ipv6: Bool) -> String? {
        guard text.count == (ipv6 ? 32 : 8) else { return nil }
        let characters = Array(text)
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: characters.count, by: 8) {
            guard let word = UInt32(String(characters[index..<index + 8]), radix: 16) else { return nil }
            // procfs prints each native-endian 32-bit word in hexadecimal.
            withUnsafeBytes(of: word) { bytes.append(contentsOf: $0) }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let succeeded = bytes.withUnsafeBytes { pointer in
            inet_ntop(ipv6 ? AF_INET6 : AF_INET, pointer.baseAddress, &output, socklen_t(output.count)) != nil
        }
        return succeeded ? String(cString: output) : nil
    }
}
