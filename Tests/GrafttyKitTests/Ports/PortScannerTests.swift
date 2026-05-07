// Tests/GrafttyKitTests/Ports/PortScannerTests.swift
import Testing
import Foundation
@testable import GrafttyKit

actor StubLsofRunner: LsofRunner {
    var output: String?
    var calls: [String] = []
    init(output: String? = "") { self.output = output }
    func run(pids: String) async -> String? {
        calls.append(pids)
        return output
    }
    func setOutput(_ value: String?) { self.output = value }
}

struct StubProcessTreeWalker: ProcessTreeWalking {
    let result: [pid_t]
    func descendants(of root: pid_t) -> [pid_t] { [root] + result }
}

@Suite("PortScanner")
struct PortScannerTests {
    @Test("""
@spec PORTS-4.1: Registered pane with no listeners produces empty bindings
""")
    func noListenersEmptyBindings() async {
        let runner = StubLsofRunner(output: "")
        let walker = StubProcessTreeWalker(result: [])
        let scanner = PortScanner(runner: runner, walker: walker)
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        let bindings = await scanner.bindings(for: id)
        #expect(bindings.isEmpty)
    }

    @Test("""
@spec PORTS-2.2: Single IPv4 loopback listener becomes one .loopback binding
""")
    func loopbackBinding() async {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    1234 a       23u  IPv4 0x1           0t0   TCP 127.0.0.1:3000 (LISTEN)
        """
        let scanner = PortScanner(
            runner: StubLsofRunner(output: raw),
            walker: StubProcessTreeWalker(result: [])
        )
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        let bindings = await scanner.bindings(for: id)
        #expect(bindings.count == 1)
        #expect(bindings[0].port == 3000)
        #expect(bindings[0].scope == .loopback)
    }

    @Test("""
@spec PORTS-2.1: Same PID with IPv4 + IPv6 binds on same port collapses to one binding
""")
    func dualStackCollapsesToLan() async {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    1234 a       23u  IPv4 0x1           0t0   TCP 0.0.0.0:3000 (LISTEN)
        node    1234 a       24u  IPv6 0x2           0t0   TCP *:3000 (LISTEN)
        """
        let scanner = PortScanner(
            runner: StubLsofRunner(output: raw),
            walker: StubProcessTreeWalker(result: [])
        )
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        let bindings = await scanner.bindings(for: id)
        #expect(bindings.count == 1)
        #expect(bindings[0].port == 3000)
        #expect(bindings[0].scope == .lan)
    }

    @Test("""
@spec PORTS-2.3: Forked workers collapse to one binding with lowest PID
""")
    func forkedWorkersCollapseToLowestPID() async {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        gunicorn 5000 a       3u   IPv4 0x1           0t0   TCP 127.0.0.1:8000 (LISTEN)
        gunicorn 5001 a       3u   IPv4 0x2           0t0   TCP 127.0.0.1:8000 (LISTEN)
        gunicorn 4999 a       3u   IPv4 0x3           0t0   TCP 127.0.0.1:8000 (LISTEN)
        """
        let scanner = PortScanner(
            runner: StubLsofRunner(output: raw),
            walker: StubProcessTreeWalker(result: [4999, 5000, 5001])
        )
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        let bindings = await scanner.bindings(for: id)
        #expect(bindings.count == 1)
        #expect(bindings[0].pid == 4999)
    }

    @Test("""
@spec PORTS-4.2: Unregister drops the snapshot
""")
    func unregisterDropsSnapshot() async {
        let raw = """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    1234 a       23u  IPv4 0x1           0t0   TCP 127.0.0.1:3000 (LISTEN)
        """
        let scanner = PortScanner(
            runner: StubLsofRunner(output: raw),
            walker: StubProcessTreeWalker(result: [])
        )
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).count == 1)
        await scanner.unregisterPane(id)
        #expect(await scanner.bindings(for: id).isEmpty)
    }

    @Test("""
@spec PORTS-1.4: Lsof failure leaves snapshot empty
""")
    func lsofFailureEmpty() async {
        let scanner = PortScanner(
            runner: StubLsofRunner(output: nil),
            walker: StubProcessTreeWalker(result: [])
        )
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).isEmpty)
    }

    @Test("""
@spec PORTS-1.3: Tick during in-flight scan is dropped (single-flight invariant)
""")
    func ports_1_3_singleFlight() async {
        actor SlowRunner: LsofRunner {
            var calls = 0
            func run(pids: String) async -> String? {
                calls += 1
                try? await Task.sleep(for: .milliseconds(50))
                return ""
            }
        }
        let runner = SlowRunner()
        let scanner = PortScanner(runner: runner, walker: StubProcessTreeWalker(result: []))
        await scanner.registerPane(TerminalID(), shellPID: 1)
        async let a: () = scanner.tick()
        async let b: () = scanner.tick()
        _ = await (a, b)
        #expect(await runner.calls == 1)
    }

    @Test("""
@spec PORTS-4.4: Tick clears bindings when previous scan had them but new scan has none
""")
    func clearOnDisappearance() async {
        let runner = StubLsofRunner(output: """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    1234 a       23u  IPv4 0x1           0t0   TCP 127.0.0.1:3000 (LISTEN)
        """)
        let scanner = PortScanner(
            runner: runner,
            walker: StubProcessTreeWalker(result: [])
        )
        let id = TerminalID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).count == 1)
        await runner.setOutput("")
        await scanner.tick()
        #expect(await scanner.bindings(for: id).isEmpty)
    }
}
