import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebSession")
struct WebSessionTests {

    private static func makeTempDir(prefix: String = "web-session") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func makeFakeZmx(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        let argvFile = dir.appendingPathComponent("argv.txt").path
        let zmxDirFile = dir.appendingPathComponent("zmx-dir.txt").path
        let termFile = dir.appendingPathComponent("term.txt").path
        let body = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(shellQuoted(argvFile))
        printf '%s\\n' "$ZMX_DIR" > \(shellQuoted(zmxDirFile))
        trap 'printf TERM > \(shellQuoted(termFile)); exit 0' TERM
        while :; do sleep 0.05; done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return script
    }

    private static func waitForFile(_ url: URL, timeout: TimeInterval = 2.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @Test("""
    @spec WEB-4.4: For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).
    """)
    func startSpawnsZmxAttachForSession() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeFakeZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let session = WebSession(config: .init(
            zmxExecutable: fakeZmx,
            zmxDir: zmxDir,
            sessionName: "graftty-abcdef12"
        ))
        try session.start()
        defer { session.close() }

        let argvURL = dir.appendingPathComponent("argv.txt")
        #expect(Self.waitForFile(argvURL))
        let argv = try String(contentsOf: argvURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        #expect(argv.count == 3)
        #expect(argv[0] == "attach")
        #expect(argv[1] == "graftty-abcdef12")

        let zmxDirText = try String(
            contentsOf: dir.appendingPathComponent("zmx-dir.txt"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(zmxDirText == zmxDir.path)
    }

    @Test("""
    @spec WEB-4.5: When a WebSocket closes, the application shall send SIGTERM to the associated `zmx attach` child, leaving the zmx daemon alive.
    """)
    func closeSendsSIGTERMToAttachChild() throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeFakeZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let session = WebSession(config: .init(
            zmxExecutable: fakeZmx,
            zmxDir: zmxDir,
            sessionName: "graftty-fedcba98"
        ))
        try session.start()
        #expect(Self.waitForFile(dir.appendingPathComponent("argv.txt")))

        session.close()

        let termURL = dir.appendingPathComponent("term.txt")
        #expect(Self.waitForFile(termURL))
        let termText = try String(contentsOf: termURL, encoding: .utf8)
        #expect(termText == "TERM")
    }

    @Test func attachProcessStartsInConfiguredWorktreeDirectory() throws {
        let root = try Self.makeTempDir(prefix: "web-session-cwd")
        let worktree = root.appendingPathComponent("repo/.worktrees/feature", isDirectory: true)
        let zmxDir = root.appendingPathComponent("zmx", isDirectory: true)
        let fakeZmx = root.appendingPathComponent("zmx-fake")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expectedCwds = [worktree.path, "/private\(worktree.path)"]

        try """
        #!/bin/sh
        printf 'cwd:%s\\n' "$PWD"
        sleep 1
        """.write(to: fakeZmx, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeZmx.path)

        let session = WebSession(config: WebSession.Config(
            zmxExecutable: fakeZmx,
            zmxDir: zmxDir,
            sessionName: "graftty-test",
            workingDirectory: worktree
        ))
        let lock = NSLock()
        var output = Data()
        let sawCwd = DispatchSemaphore(value: 0)
        session.onPTYData = { data in
            lock.lock()
            output.append(data)
            let text = String(data: output, encoding: .utf8) ?? ""
            lock.unlock()
            if expectedCwds.contains(where: { text.contains("cwd:\($0)") }) {
                sawCwd.signal()
            }
        }
        try session.start()
        defer { session.close() }

        let result = sawCwd.wait(timeout: .now() + 3)
        lock.lock()
        let text = String(data: output, encoding: .utf8) ?? ""
        lock.unlock()
        #expect(result == .success, "expected fake zmx to start in \(expectedCwds), got output: \(text)")
    }
}
