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
    @Test("@spec PORTS-4.6: If a pane is unregistered or its shell is replaced during a port scan, then the application shall discard that scan's obsolete bindings and shall not restore the removed registration.")
    func unregistrationDuringScanDoesNotRestorePorts() async {
        actor SuspendedRunner: LsofRunner {
            var started = false
            var suspended = false
            var continuation: CheckedContinuation<String?, Never>?
            func run(pids: String) async -> String? {
                if !suspended { return "node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)" }
                started = true
                return await withCheckedContinuation { continuation = $0 }
            }
            func suspend() { suspended = true }
            func finish() {
                continuation?.resume(returning: "node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)")
                continuation = nil
            }
        }
        for replacement in [0, 1, 2] {
            let runner = SuspendedRunner()
            let scanner = PortScanner(runner: runner, walker: StubProcessTreeWalker(result: []))
            let id = PaneSlotID()
            await scanner.registerPane(id, shellPID: 1234)
            await scanner.tick()
            #expect(await scanner.bindings(for: id).count == 1)
            await runner.suspend()
            let scan = Task { await scanner.tick() }
            while !(await runner.started) { await Task.yield() }
            if replacement == 1 { await scanner.registerPane(id, shellPID: 2345) }
            else if replacement == 2 {
                await scanner.unregisterPane(id)
                await scanner.registerPane(id, shellPID: 1234)
            }
            else { await scanner.unregisterPane(id) }
            #expect(await scanner.bindings(for: id).isEmpty)
            await runner.finish()
            await scan.value
            #expect(await scanner.bindings(for: id).isEmpty)
        }
    }

    @Test("@spec PORTS-4.7: If a pending pane is unregistered and registered again while its PID is resolving, then the application shall discard the old resolution and resolve the new registration independently.")
    func replacedPendingRegistrationDiscardsOldResolution() async {
        actor Resolver {
            var started = false
            var continuation: CheckedContinuation<pid_t?, Never>?
            func resolve() async -> pid_t? {
                if started { return 2345 }
                started = true
                return await withCheckedContinuation { continuation = $0 }
            }
            func finish() { continuation?.resume(returning: 1234); continuation = nil }
        }
        let resolver = Resolver()
        let runner = StubLsofRunner(output: """
            node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)
            vite 2345 alice 23u IPv4 0x2 0t0 TCP 127.0.0.1:4000 (LISTEN)
            """)
        let scanner = PortScanner(runner: runner, walker: StubProcessTreeWalker(result: []))
        await scanner.setPIDResolver { _ in await resolver.resolve() }
        let id = PaneSlotID()
        await scanner.registerPanePending(id)
        let scan = Task { await scanner.tick() }
        while !(await resolver.started) { await Task.yield() }
        await scanner.unregisterPane(id)
        await scanner.registerPanePending(id)
        await resolver.finish()
        await scan.value
        #expect(await scanner.bindings(for: id).isEmpty)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).map(\.port) == [4000])
    }

    @Test("@spec PORTS-5.7: When opening a worktree port, the application shall refresh discovery before resolving the listener and reject ports whose processes stopped after the last published snapshot.")
    func refreshBeforeOpeningDropsStoppedListener() async {
        let runner = StubLsofRunner(output: "node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)")
        let scanner = PortScanner(runner: runner, walker: StubProcessTreeWalker(result: []))
        let id = PaneSlotID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).count == 1)
        await runner.setOutput("")
        #expect(await scanner.refreshedPorts(for: [id]).isEmpty)
        #expect(await runner.calls.count == 2)
    }

    @Test("@spec PORTS-5.8: When different worktrees listen on the same port on separate IPv4 and IPv6 addresses, the application shall preserve each listener's exact address so opening one worktree cannot resolve to the other.")
    func loopbackFamiliesStayDistinct() async {
        let scanner = PortScanner(runner: StubLsofRunner(output: """
            node 1234 alice 23u IPv4 0x1 0t0 TCP 127.0.0.1:3000 (LISTEN)
            node 2345 alice 23u IPv6 0x2 0t0 TCP [::1]:3000 (LISTEN)
            node 3456 alice 23u IPv6 0x3 0t0 TCP *:8080 (LISTEN)
            """), walker: StubProcessTreeWalker(result: []))
        let first = PaneSlotID(), second = PaneSlotID(), wildcard = PaneSlotID()
        await scanner.registerPane(first, shellPID: 1234)
        await scanner.registerPane(second, shellPID: 2345)
        await scanner.registerPane(wildcard, shellPID: 3456)
        await scanner.tick()
        #expect(await scanner.bindings(for: first).first?.host == "127.0.0.1")
        #expect(await scanner.bindings(for: second).first?.host == "::1")
        #expect(await scanner.bindings(for: wildcard).first?.host == "::1")
    }

    @Test("@spec PORTS-5.6: When a worktree process listens only on a specific host interface, the application shall retain that listener's address for opening the port rather than assume localhost.")
    func preservesSpecificListenerAddress() async {
        let scanner = PortScanner(runner: StubLsofRunner(output:
            "node 1234 alice 23u IPv4 0x1 0t0 TCP 192.168.1.5:3000 (LISTEN)"), walker: StubProcessTreeWalker(result: []))
        let id = PaneSlotID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).first?.host == "192.168.1.5")
    }

    @Test("""
@spec PORTS-4.1: Registered pane with no listeners produces empty bindings
""")
    func noListenersEmptyBindings() async {
        let runner = StubLsofRunner(output: "")
        let walker = StubProcessTreeWalker(result: [])
        let scanner = PortScanner(runner: runner, walker: walker)
        let id = PaneSlotID()
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
        let id = PaneSlotID()
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
        let id = PaneSlotID()
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
        let id = PaneSlotID()
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
        let id = PaneSlotID()
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
        let id = PaneSlotID()
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
        await scanner.registerPane(PaneSlotID(), shellPID: 1)
        async let a: () = scanner.tick()
        async let b: () = scanner.tick()
        _ = await (a, b)
        #expect(await runner.calls == 1)
    }

    @Test("""
@spec PORTS-4.5: When a pane is registered before its shell PID can be resolved (e.g., the zmx daemon log has not yet written the `pty spawned` line), the application shall record the pane as pending and re-attempt resolution on each scan tick until it succeeds; once resolved, the pane shall begin participating in scans.
""")
    func resolvesPendingPaneOnLaterTick() async {
        actor PIDBox {
            var calls = 0
            var pid: pid_t? = nil
            func resolve(_: PaneSlotID) async -> pid_t? {
                calls += 1
                return pid
            }
            func setPID(_ p: pid_t?) { self.pid = p }
        }
        let box = PIDBox()
        let runner = StubLsofRunner(output: """
        COMMAND   PID  USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        node    1234 a       23u  IPv4 0x1           0t0   TCP 127.0.0.1:3000 (LISTEN)
        """)
        let scanner = PortScanner(
            runner: runner,
            walker: StubProcessTreeWalker(result: [])
        )
        await scanner.setPIDResolver { id in await box.resolve(id) }
        let id = PaneSlotID()
        await scanner.registerPanePending(id)

        // Tick 1: resolver returns nil, pane stays pending, no scan output.
        await scanner.tick()
        #expect(await scanner.bindings(for: id).isEmpty)
        #expect(await box.calls == 1)
        #expect(await runner.calls.isEmpty)

        // Resolver now returns a real PID.
        await box.setPID(1234)
        await scanner.tick()

        let bindings = await scanner.bindings(for: id)
        #expect(bindings.count == 1)
        #expect(bindings.first?.port == 3000)
        // Tick 3: pane is resolved, resolver shouldn't be re-queried.
        await scanner.tick()
        #expect(await box.calls == 2)
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
        let id = PaneSlotID()
        await scanner.registerPane(id, shellPID: 1234)
        await scanner.tick()
        #expect(await scanner.bindings(for: id).count == 1)
        await runner.setOutput("")
        await scanner.tick()
        #expect(await scanner.bindings(for: id).isEmpty)
    }
}
