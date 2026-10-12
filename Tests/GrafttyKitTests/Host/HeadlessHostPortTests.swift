import Foundation
import Testing
@testable import GrafttyKit
import GrafttyProtocol

@MainActor
private final class PortHostTerminalFake: HostTerminalDriver {
    var live: Set<String> = []
    func sessions() async throws -> Set<String> { live }
    func start(_ configuration: ZmxSpawnConfiguration) async throws { live.insert(configuration.sessionName) }
    func kill(_ session: String) async throws { live.remove(session) }
    func send(_ text: String, to session: String) async throws {}
    func show(_ session: String, lines: Int) async throws -> String { "" }
    func detachAll() {}
}

@MainActor
struct HeadlessHostPortTests {
    @Test("@spec PORTS-5.5: While a headless pane is running, the application shall discover listeners from its current zmx shell subtree, publish them under its session name, retry missing PIDs, and clear bindings when the session closes or its PID disappears.")
    func runtimeTracksSessionPorts() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("ports-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = HostConfiguration(stateDirectory: root, runtimeDirectory: root.appendingPathComponent("run"), zmxExecutable: URL(fileURLWithPath: "/bin/true"))
        let state = AppState(repos: [RepoEntry(path: root.path, displayName: "project", worktrees: [WorktreeEntry(path: root.path, branch: "main")])])
        let scanner = PortScanner(runner: StubLsofRunner(output: "node 123 user 3u IPv6 0x0 0t0 TCP [::1]:3000 (LISTEN)"), walker: StubProcessTreeWalker(result: []))
        let terminals = PortHostTerminalFake()
        var runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, initialState: state, portScanner: scanner)
        let session = try await runtime.openWorktree(root.path)
        await runtime.refreshPortBindings()
        #expect(runtime.snapshot().first?.portBindings?[session]?.isEmpty != false)
        let log = runtime.launcher.logFile(forSession: session)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("pty spawned session=\(session) pid=123\n".utf8).write(to: log)
        await runtime.refreshPortBindings()
        #expect(runtime.snapshot().first?.portBindings?[session]?.first?.port == 3000)
        #expect(runtime.snapshot().first?.portBindings?[session]?.first?.targetHost == "::1")
        // Restart from persisted state while the zmx session survives.
        runtime = try HeadlessHostRuntime(configuration: config, terminals: terminals, portScanner: scanner)
        try await runtime.restore()
        #expect(runtime.snapshot().first?.portBindings?[session]?.first?.port == 3000)
        try FileManager.default.removeItem(at: log)
        await runtime.refreshPortBindings()
        #expect(runtime.snapshot().first?.portBindings?[session]?.isEmpty != false)
        try Data("pty spawned session=\(session) pid=123\n".utf8).write(to: log)
        await runtime.refreshPortBindings()
        #expect(runtime.snapshot().first?.portBindings?[session]?.count == 1)
        try await runtime.closePane(target: session)
        #expect(runtime.snapshot().first?.portBindings?[session] == nil)
    }
}
