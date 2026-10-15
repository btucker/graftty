import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit
import GrafttyProtocol

struct OpenCLITests {
    @MainActor
    @Test("@spec IOS-12.9: When graftty open successfully enqueues a resource, the CLI shall stay quiet without claiming browser completion, and shall propagate host rejection and transport failures.", .timeLimit(.minutes(1)))
    func successfulOpenIsQuietAndFailuresPropagate() async throws {
        let executable = try openExecutable()
        let root = URL(fileURLWithPath: "/tmp/graftty-open-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("s").path
        let target = "https://example.com/?q=A%2Bb#part"
        let expected = Open.request(path: "", target: target, environment: ["ZMX_SESSION": "fixture-pane"])
        let server = SocketServer(socketPath: socket)
        defer { server.stop() }
        for response in [ResponseMessage.ok, .error("Fixture host denied")] {
            var received: NotificationMessage?
            server.onRequest = { message in received = message; return response }
            try server.start()
            let result = try await runOpen(executable: executable, target: target, socket: socket)
            #expect(received == expected)
            #expect(result.stdout.isEmpty)
            if response == .ok {
                #expect(result.status == 0)
                #expect(result.stderr.isEmpty)
            } else {
                #expect(result.status != 0)
                #expect(result.stderr.contains("Fixture host denied"))
            }
            server.stop()
        }
        let disconnected = try await runOpen(executable: executable, target: target,
                                             socket: root.appendingPathComponent("missing").path)
        #expect(disconnected.status != 0)
        #expect(disconnected.stdout.isEmpty)
        #expect(!disconnected.stderr.isEmpty)
    }

    private func openExecutable() throws -> URL {
        // Swift Testing can run inside a separate runner, so Bundle.main is
        // not necessarily the package's test bundle or product directory.
        let locations = [Bundle(for: OpenCLITestBundleAnchor.self).bundleURL,
                         URL(fileURLWithPath: CommandLine.arguments[0])]
        for location in locations {
            var directory = location.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("graftty-cli")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        throw NSError(domain: "OpenCLITests", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "The package's graftty-cli executable must be built beside its test bundle."])
    }

    @MainActor
    private func runOpen(executable: URL, target: String, socket: String) async throws
        -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["open", target]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_SOCK"] = socket
        environment["ZMX_SESSION"] = "fixture-pane"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning, "The isolated open command did not finish before its deadline")
        return (process.terminationStatus,
                String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    @Test("@spec IOS-12.3: When the user runs graftty open with a file path, the CLI shall send the caller's pane session with the file in its tracked worktree and report request failures.")
    func parsesFileArgumentAndEncodesRequest() throws {
        let command = try Open.parse(["./report with spaces.html"])
        #expect(command.target == "./report with spaces.html")
        #expect(throws: (any Error).self) { try Open.parse([]) }
        let message = Open.request(path: "/project", target: "/tmp/report.html", environment: ["ZMX_SESSION": "graftty-pane"])
        #expect(message == .offerResource(path: "/project", target: "/tmp/report.html", paneSessionName: "graftty-pane"))
        #expect(message.expectsResponse)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(message)) == message)
        let oldMessage = Data(#"{"type":"open_resource","path":"/project","target":"/tmp/report.html"}"#.utf8)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: oldMessage) ==
            .offerResource(path: "/project", target: "/tmp/report.html"))
    }

    @Test("@spec PORTS-5.39: When a pane opens a resource after changing directory, the application shall resolve its originating worktree from the pane session and reject an unknown session instead of opening on another device.")
    func routesUsingPaneRatherThanWorkingDirectory() throws {
        let slot = PaneSlotID(id: UUID())
        let session = PaneSessionID(id: UUID())
        var origin = WorktreeEntry(path: "/project/a", branch: "a")
        origin.paneSessions[slot] = session
        let other = WorktreeEntry(path: "/project/b", branch: "b")
        let state = AppState(repos: [RepoEntry(path: "/project", displayName: "Project", worktrees: [origin, other])])
        let name = ZmxLauncher.sessionName(for: session)
        // Do not query cwd when a pane supplies the authoritative session.
        #expect(try Open.worktreePath(environment: ["ZMX_SESSION": name]) { throw CocoaError(.fileNoSuchFile) } == "")
        #expect(Open.worktreePath(environment: [:]) { other.path } == other.path)
        #expect(OpenResourceRouting.worktree(path: "/tmp", paneSessionName: name, state: state) == origin)
        #expect(OpenResourceRouting.worktree(path: other.path, paneSessionName: name, state: state) == origin)
        #expect(OpenResourceRouting.worktree(path: other.path, paneSessionName: "gone", state: state) == nil)
        #expect(OpenResourceRouting.worktree(path: other.path, paneSessionName: nil, state: state) == other)
    }

    @Test("@spec IOS-12.8: When graftty open runs in a pane led by GrafttyMobile, the host shall offer its resource to mobile; when Mac or another client leads or no pane session is supplied, the host shall open it with macOS.")
    func routesByPaneOwnership() throws {
        let store = SessionDisplayOwnershipStore()
        let session = "graftty-pane"
        let client = DisplayClientID("phone")
        let grid = try DisplayGrid(cols: 80, rows: 24)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mac)
        _ = store.attachClient(sessionName: session, clientID: client, kind: .ios, role: .interactive, visible: true, grid: grid)
        _ = store.claimOwner(sessionName: session, clientID: client, kind: .ios, grid: grid)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mobile)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: false, ownershipStore: store) == .mac)
        #expect(OpenResourceRouting.destination(
            paneSessionName: nil, belongsToWorktree: false, ownershipStore: store) == .mac)
        _ = store.releaseOwner(sessionName: session, clientID: client)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mac)
        let mac = DisplayClientID("mac")
        _ = store.attachClient(sessionName: session, clientID: mac, kind: .mac, role: .interactive, visible: true, grid: grid)
        _ = store.claimOwner(sessionName: session, clientID: mac, kind: .mac, grid: grid)
        #expect(OpenResourceRouting.destination(
            paneSessionName: session, belongsToWorktree: true, ownershipStore: store) == .mac)
    }
}

private final class OpenCLITestBundleAnchor: NSObject {}
