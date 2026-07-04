import Testing
import Foundation
@testable import GrafttyKit

@Suite("WebSession")
struct WebSessionTests {

    private static func makeFakeZmx(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        let argvFile = dir.appendingPathComponent("argv.txt").path
        let zmxDirFile = dir.appendingPathComponent("zmx-dir.txt").path
        let termFile = dir.appendingPathComponent("term.txt").path
        let body = """
        #!/bin/sh
        printf '%s\\n' "$@" > \(PTYFixtureTestSupport.shellQuoted(argvFile))
        printf '%s\\n' "$ZMX_DIR" > \(PTYFixtureTestSupport.shellQuoted(zmxDirFile))
        trap 'printf TERM > \(PTYFixtureTestSupport.shellQuoted(termFile)); exit 0' TERM
        while :; do sleep 0.05; done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return script
    }

    /// Fake zmx that dumps its inherited env to `env.txt` so a test can
    /// assert which variables WebSession propagated to the spawned
    /// `zmx attach` child. Variables propagated here become the user
    /// shell's env when this `zmx attach` is the one that creates the
    /// daemon session (the create-session race symptom that motivates
    /// WEB-4.10 — see test below).
    private static func makeEnvCapturingZmx(in dir: URL) throws -> URL {
        let script = dir.appendingPathComponent("zmx")
        let envFile = dir.appendingPathComponent("env.txt").path
        let body = """
        #!/bin/sh
        # Write-then-rename so the file only appears once its content is
        # complete: a bare `env > file` creates the file on redirect-open,
        # and under parallel test load the scheduler can preempt between
        # that open and env's write — waitForFile would then admit a
        # reader to an empty file (the WEB-4.10 TERM-nil flake).
        env > \(PTYFixtureTestSupport.shellQuoted(envFile)).tmp
        /bin/mv \(PTYFixtureTestSupport.shellQuoted(envFile)).tmp \(PTYFixtureTestSupport.shellQuoted(envFile))
        while :; do sleep 0.05; done
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )
        return script
    }

    /// Tiny Sendable counter for observing `@Sendable` callbacks
    /// (`RemoteAttachmentRegistry.onLastDetach`) that can't capture
    /// local `var`s.
    private final class LockedCounterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
        func value() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    @Test("""
    @spec WEB-4.4: For each incoming WebSocket, the application shall spawn one child `zmx attach <session>` whose PTY it owns (per §13 naming and ZMX_DIR rules from Phase 1).
    """)
    func startSpawnsZmxAttachForSession() throws {
        let dir = try PTYFixtureTestSupport.makeTempDir(prefix: "web-session")
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
        #expect(PTYFixtureTestSupport.waitForFile(argvURL))
        let argv = try String(contentsOf: argvURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        // ZMX-6.6: attach now relies on zmx's default login spawn (no positional shell).
        #expect(argv.count == 2)
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
        let dir = try PTYFixtureTestSupport.makeTempDir(prefix: "web-session")
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
        #expect(PTYFixtureTestSupport.waitForFile(dir.appendingPathComponent("argv.txt")))

        session.close()

        let termURL = dir.appendingPathComponent("term.txt")
        #expect(PTYFixtureTestSupport.waitForFile(termURL))
        let termText = try String(contentsOf: termURL, encoding: .utf8)
        #expect(termText == "TERM")
    }

    @Test("""
    @spec WEB-4.10: When the WebSocket bridge spawns a `zmx attach` child to back a mobile-client session, the application shall propagate the same shell-integration env (`TERM`, `COLORTERM`, `TERM_PROGRAM`, `TERMINFO` when ghostty-terminfo is available, and `ZDOTDIR` pointing at Ghostty's zsh shell-integration when the user's shell is zsh) that host-managed native panes use (per `ZMX-6.3` / `ZMX-6.5`). Without this, the WS attach can win the create-session race against the Mac surface's attach (which is slow because it follows `git worktree add` + discovery) and spawn the daemon's user shell with no shell integration — silencing the first-PWD trigger (so the host pane never types the user's default command) and leaving the shell without truecolor.
    """)
    func startPropagatesTerminalCapabilitiesAndZshIntegrationEnv() throws {
        let dir = try PTYFixtureTestSupport.makeTempDir(prefix: "web-session")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeEnvCapturingZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        // Use a temp ghostty-resources path with no terminfo siblings so
        // TERM resolves to the `xterm-256color` fallback regardless of
        // whether Ghostty is installed on the test machine. ZDOTDIR is
        // still set from this path, which is what we want to verify.
        let fakeResources = dir.appendingPathComponent("ghostty-resources", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeResources, withIntermediateDirectories: true)

        let session = WebSession(config: .init(
            zmxExecutable: fakeZmx,
            zmxDir: zmxDir,
            sessionName: "graftty-cafebabe"
        ))
        // `processEnvForTesting` lets the test inject SHELL + GHOSTTY_RESOURCES_DIR
        // without leaking into the real environment; the impl falls back to
        // ProcessInfo when nil. Without this hook, this test would depend on
        // the CI runner's SHELL setting.
        session.processEnvForTesting = [
            "SHELL": "/bin/zsh",
            "PATH": "/usr/bin",
            "GHOSTTY_RESOURCES_DIR": fakeResources.path,
        ]
        try session.start()
        defer { session.close() }

        let envURL = dir.appendingPathComponent("env.txt")
        #expect(PTYFixtureTestSupport.waitForFile(envURL))
        let envText = try String(contentsOf: envURL, encoding: .utf8)
        let envPairs = envText
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .reduce(into: [String: String]()) { dict, line in
                let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    dict[String(parts[0])] = String(parts[1])
                }
            }

        // Color: TERM falls back to `xterm-256color` because the temp
        // ghostty-resources path has no terminfo sibling. COLORTERM +
        // TERM_PROGRAM are unconditional.
        #expect(envPairs["TERM"] == "xterm-256color")
        #expect(envPairs["COLORTERM"] == "truecolor")
        #expect(envPairs["TERM_PROGRAM"] == "ghostty")

        // Default-command: ZDOTDIR points at ghostty's zsh shell-integration so
        // the shell's first-prompt hook fires OSC 7 / OSC 133, the host
        // surface's `onShellReady` fires, and `maybeRunDefaultCommand` types
        // the configured command.
        let expectedZDOTDIR = fakeResources.appendingPathComponent("shell-integration/zsh").path
        #expect(envPairs["ZDOTDIR"] == expectedZDOTDIR)
    }

    @Test("WebSession shall register with the RemoteAttachmentRegistry on successful start and deregister exactly once on close (TERM-11.5).")
    func registersAttachOnStartAndDetachOnClose() throws {
        let dir = try PTYFixtureTestSupport.makeTempDir(prefix: "web-session-registry")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeZmx = try Self.makeFakeZmx(in: dir)
        let zmxDir = dir.appendingPathComponent("zmx-state", isDirectory: true)
        try FileManager.default.createDirectory(at: zmxDir, withIntermediateDirectories: true)

        let registry = RemoteAttachmentRegistry()
        let session = WebSession(config: WebSession.Config(
            zmxExecutable: fakeZmx,
            zmxDir: zmxDir,
            sessionName: "reg-test"
        ))
        session.attachmentRegistry = registry

        try session.start()
        #expect(registry.isRemoteAttached(sessionName: "reg-test"))

        session.close()
        #expect(!registry.isRemoteAttached(sessionName: "reg-test"))

        // close() is re-entrant (channelInactive can follow connectionClose);
        // a second close must not double-detach. With an extra attach
        // standing in for another remote client, a double-detach would
        // wrongly drop the count to zero.
        registry.attach(sessionName: "reg-test")
        session.close()
        #expect(registry.isRemoteAttached(sessionName: "reg-test"))
    }

    @Test("WebSession shall not deregister on close when start never succeeded (TERM-11.5).")
    func closeWithoutStartDoesNotDetach() {
        let registry = RemoteAttachmentRegistry()
        let fired = LockedCounterBox()
        registry.onLastDetach = { _ in fired.increment() }
        let session = WebSession(config: WebSession.Config(
            zmxExecutable: URL(fileURLWithPath: "/nonexistent-zmx"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            sessionName: "never-started"
        ))
        session.attachmentRegistry = registry

        // Another client's attach under the same name: a spurious detach
        // from the never-started session would drop it to zero and fire
        // the observer.
        registry.attach(sessionName: "never-started")
        // NB: the failed-SPAWN branch can't be driven from here —
        // PtyProcess.spawn is fork-based, so a bogus executable still
        // yields a pid and start() succeeds (the child dies at exec).
        // This test covers close()-without-start() only.
        session.close()
        #expect(registry.isRemoteAttached(sessionName: "never-started"))
        #expect(fired.value() == 0)
    }

    @Test func attachProcessStartsInConfiguredWorktreeDirectory() throws {
        let root = try PTYFixtureTestSupport.makeTempDir(prefix: "web-session-cwd")
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
