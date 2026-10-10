import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

struct LinuxProcSocketScannerTests {
    @Test("@spec PORTS-5.1: When pane port metadata is sent, the application shall preserve session-scoped bindings and safe loopback targets while decoding older snapshots without port metadata.")
    func wireRoundTrip() throws {
        let old = Data(#"{"path":"/repo","displayName":"main","repoDisplayName":"repo"}"#.utf8)
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: old).portBindings == nil)
        let binding = PortBinding(port: 3000, scope: .loopback, processName: "node", pid: 12, targetHost: "::1")
        let row = WorktreePanes(path: "/repo", displayName: "main", repoDisplayName: "repo", displayBranch: "main", state: .running, isMainCheckout: true, prBadge: nil, stats: nil, attentionText: nil, layout: nil, portBindings: ["pane": [binding]])
        #expect(try JSONDecoder().decode(WorktreePanes.self, from: JSONEncoder().encode(row)) == row)
        let legacy = Data(#"{"port":3000,"scope":"loopback","processName":"node","pid":12}"#.utf8)
        #expect(try JSONDecoder().decode(PortBinding.self, from: legacy).targetHost == nil)
    }

    @Test("@spec PORTS-5.2: While scanning Linux panes, the application shall discover only TCP listeners owned by the requested process subtree from procfs without requiring lsof, ignoring missing processes and unowned sockets.")
    func procSocketOwnershipAndAddresses() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["net", "123/fd", "456/fd"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try Data("node\n".utf8).write(to: root.appendingPathComponent("123/comm"))
        try Data("other\n".utf8).write(to: root.appendingPathComponent("456/comm"))
        for (fd, inode) in [(3, 100), (4, 101), (5, 102)] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("123/fd/\(fd)").path, withDestinationPath: "socket:[\(inode)]")
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("456/fd/3").path, withDestinationPath: "socket:[103]")
        // IPv4 local host, established (not listening), and unrelated listener.
        try Data("""
        sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode
        0: 0100007F:0BB8 00000000:0000 0A 0:0 0:0 0 1000 0 100
        1: 0100007F:0BB9 00000000:0000 01 0:0 0:0 0 1000 0 102
        2: 00000000:0BBA 00000000:0000 0A 0:0 0:0 0 1000 0 103
        """.utf8).write(to: root.appendingPathComponent("net/tcp"))
        try Data("0: 00000000000000000000000001000000:1F90 00000000000000000000000000000000:0000 0A 0:0 0:0 0 1000 0 101\n".utf8).write(to: root.appendingPathComponent("net/tcp6"))
        let scanner = LinuxProcSocketScanner(procRoot: root)
        let rows = try #require(await scanner.listeningSockets(pids: [123, 999]))
        #expect(rows.count == 2)
        #expect(rows.contains { $0.address == "127.0.0.1" && $0.port == 3000 && $0.pid == 123 })
        #expect(rows.contains { $0.address == "::1" && $0.port == 8080 && $0.processName == "node" })
        #expect(await scanner.listeningSockets(pids: [999]) == [])
    }

    @Test("@spec PORTS-5.3: When listener rows are collapsed, the application shall retain a reachable IPv4 or IPv6 loopback target and shall not invent a loopback route for a specific LAN address.")
    func loopbackTargets() {
        for (address, target, scope) in [("127.0.0.2", "127.0.0.2" as String?, BindScope.loopback), ("::1", "::1", .loopback), ("0.0.0.0", "127.0.0.1", .lan), ("::", "::1", .lan), ("192.0.2.4", nil, .lan)] {
            let rows = LsofOutputParser.parse("node 123 user 3u IPv6 0x0 0t0 TCP [\(address)]:3000 (LISTEN)")
            let binding = PortScanner.collapse(rows).first
            #expect(binding?.targetHost == target)
            #expect(binding?.scope == scope)
        }
    }
}

private actor SuspendedPortRunner: LsofRunner {
    var continuation: CheckedContinuation<String?, Never>?
    func run(pids: String) async -> String? {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() {
        continuation?.resume(returning: "node 123 user 3u IPv4 0x0 0t0 TCP 127.0.0.1:3000 (LISTEN)")
        continuation = nil
    }
    var started: Bool { continuation != nil }
}

extension LinuxProcSocketScannerTests {
    @Test("@spec PORTS-5.4: When a pane is removed or its shell PID changes during port discovery, the application shall discard the old scan rather than publish stale listeners.")
    func staleScanCannotResurrectPane() async throws {
        let runner = SuspendedPortRunner()
        let scanner = PortScanner(runner: runner, walker: StubProcessTreeWalker(result: []))
        let pane = PaneSlotID()
        await scanner.registerPane(pane, shellPID: 123)
        let tick = Task { await scanner.tick() }
        for _ in 0..<100 where !(await runner.started) { try await Task.sleep(for: .milliseconds(1)) }
        #expect(await runner.started)
        await scanner.unregisterPane(pane)
        await scanner.registerPane(pane, shellPID: 456)
        await runner.finish()
        await tick.value
        #expect(await scanner.bindings(for: pane).isEmpty)
    }
}
