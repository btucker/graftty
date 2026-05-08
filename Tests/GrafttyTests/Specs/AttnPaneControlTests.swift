import Foundation
import Testing
@testable import Graftty
@testable import GrafttyCLI
@testable import GrafttyKit

@Suite("@spec ATTN-1.15: When `pane show <addr>` is invoked against a running pane, the application shall return the last `--lines` lines (default 100) of that pane's `zmx` scrollback as plain text on the CLI's stdout.")
struct PaneShowHandlerTests {
    @Test("Tails 200 lines to the requested 50")
    @MainActor
    func tails200To50() async throws {
        let body = (1...200).map { "line\($0)" }.joined(separator: "\n")
        let stubReader = StubZmxHistoryReader(output: body)
        let response = GrafttyApp.handleShowPane_forTesting(
            path: "/wt", index: 1, lines: 50,
            reader: stubReader
        )
        guard case .paneShow(let text) = response else {
            Issue.record("expected .paneShow, got \(response)")
            return
        }
        let lines = text.split(separator: "\n")
        #expect(lines.count == 50)
        #expect(lines.first == "line151")
        #expect(lines.last == "line200")
    }

    @Test("Large scrollback (>64KB) does not deadlock the stub+tail path")
    @MainActor
    func largeScrollbackNoDeadlock() async throws {
        // Each line is ~100 bytes; 1000 lines ≈ 100KB, well past the macOS
        // pipe buffer. This exercises only the stub reader, so the actual
        // deadlock fix in `ZmxHistorySubprocessReader` isn't directly
        // covered here — but the test pins down that the stub+tail
        // integration handles large bodies cleanly.
        let body = (1...1000)
            .map { String(repeating: "x", count: 100) + "\($0)" }
            .joined(separator: "\n")
        let stub = StubZmxHistoryReader(output: body)
        let response = GrafttyApp.handleShowPane_forTesting(
            path: "/wt", index: 1, lines: 50, reader: stub
        )
        guard case .paneShow(let text) = response else {
            Issue.record("expected .paneShow, got \(response)")
            return
        }
        #expect(text.split(separator: "\n").count == 50)
    }

    private final class StubZmxHistoryReader: ZmxHistoryReader, @unchecked Sendable {
        let output: String
        init(output: String) { self.output = output }
        func history(sessionName: String) throws -> String { output }
    }
}

@Suite("@spec ATTN-1.16: When `pane send <addr> <text>` is invoked, the application shall inject `text` into the addressed pane's PTY via `ghostty_surface_text`, and unless `--no-enter` is set, shall additionally synthesize a Return key event via `ghostty_surface_key` (matching `SurfaceHandle.pressReturn`) so TUI consumers in raw mode (Codex, Claude) treat the input as committed.")
struct PaneSendHandlerTests {
    @Test("Default flag types text and presses Return")
    @MainActor
    func sendsAndCommits() async throws {
        let sink = RecordingPaneInputSink()
        let response = GrafttyApp.handleSendPane_forTesting(
            text: "pnpm test", pressEnter: true, sink: sink
        )
        #expect(response == .ok)
        #expect(sink.typedText == ["pnpm test"])
        #expect(sink.returnPresses == 1)
    }

    @Test("--no-enter types text only")
    @MainActor
    func noEnterTypesOnly() async throws {
        let sink = RecordingPaneInputSink()
        let response = GrafttyApp.handleSendPane_forTesting(
            text: "y", pressEnter: false, sink: sink
        )
        #expect(response == .ok)
        #expect(sink.typedText == ["y"])
        #expect(sink.returnPresses == 0)
    }

    private final class RecordingPaneInputSink: PaneInputSink {
        var typedText: [String] = []
        var returnPresses: Int = 0
        func typeText(_ text: String) { typedText.append(text) }
        func pressReturn() { returnPresses += 1 }
    }
}

@Suite("@spec ATTN-1.17: When any `pane` subcommand (`list`/`add`/`close`/`show`/`send`) is invoked with a `<wt>` or `<wt>:<id>` address, the application shall resolve the worktree by branch name (using the same lookup `graftty team msg` uses, against the `team list` registry) and operate on that worktree regardless of the caller's current working directory; an unknown name shall produce a stderr error and a non-zero exit.")
struct WorktreeNameResolutionTests {
    @Test("Resolves branch name to tracked worktree path")
    func resolvesBranchName() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let resolved = WorktreeNameLookup.resolvePath(name: "drag-files", stateDirectory: stateDir)
        #expect(resolved == "/tmp/wt-drag-files")
    }

    @Test("Returns nil for unknown branch name")
    func unknownNameNil() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        #expect(WorktreeNameLookup.resolvePath(name: "nope", stateDirectory: stateDir) == nil)
    }

    @Test("Matches sanitized branch name (the same form `team list` prints)")
    func matchesSanitizedName() throws {
        // `feature/drag files` sanitizes to `feature/drag-files`; the user
        // types the sanitized form (matching `team list` output) and the
        // lookup must find it against the raw branch.
        let stateDir = try makeTempStateWithWorktree(
            branch: "feature/drag files",
            path: "/tmp/wt-feature"
        )
        defer { try? FileManager.default.removeItem(at: stateDir) }
        #expect(
            WorktreeNameLookup.resolvePath(name: "feature/drag-files", stateDirectory: stateDir)
                == "/tmp/wt-feature"
        )
    }
}

@Suite("""
@spec ATTN-1.19: When `pane show` or `pane send` is invoked against a worktree that has more than one pane and the address omits the `<id>` part, the application shall print the equivalent of `pane list <wt>` to stderr, append a 'specify a pane' hint, and exit non-zero. With exactly one pane, the bare-worktree form shall target that pane.
""")
struct PaneShowAmbiguityTests {
    @Test("Bare worktree with >1 panes triggers list-and-error")
    func multiPaneBareWt() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [
            .paneList([
                PaneInfo(id: 1, title: "zsh", focused: true),
                PaneInfo(id: 2, title: "claude", focused: false),
            ])
        ]
        let stdout = CapturingTextSink()
        let stderr = CapturingTextSink()
        let exit = PaneShowDispatcher.run(
            address: "drag-files",
            lines: 100,
            transport: transport,
            stdout: stdout,
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 1)
        #expect(stderr.text.contains("specify a pane"))
        // The full list should be embedded — the equivalent of `pane list`.
        #expect(stderr.text.contains("zsh"))
        #expect(stderr.text.contains("claude"))
    }

    @Test("Bare worktree with 1 pane targets it (no error)")
    func singlePaneBareWt() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [
            .paneList([PaneInfo(id: 1, title: "zsh", focused: true)]),
            .paneShow("history-output\n"),
        ]
        let stdout = CapturingTextSink()
        let stderr = CapturingTextSink()
        let exit = PaneShowDispatcher.run(
            address: "drag-files",
            lines: 100,
            transport: transport,
            stdout: stdout,
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 0)
        #expect(stdout.text.contains("history-output"))
        #expect(stderr.text.isEmpty)
    }
}

@Suite("""
@spec ATTN-1.18: When `pane show` or `pane send` is invoked against a worktree that is not in the `running` state, the application shall fail with a `worktree not running` error rather than auto-launch the worktree's panes.
""")
struct PaneShowClosedWorktreeTests {
    @Test("Server `.error(\"worktree not running\")` is surfaced verbatim")
    func surfacesWorktreeNotRunning() throws {
        // The CLI sees a `.paneList` request return `.error("worktree not running")`
        // when the worktree is closed (per the app handler from Task 4); surface
        // the message verbatim and exit 1 — don't fall back to auto-launching.
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [.error("worktree not running")]
        let stderr = CapturingTextSink()
        let exit = PaneShowDispatcher.run(
            address: "drag-files",
            lines: 100,
            transport: transport,
            stdout: CapturingTextSink(),
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 1)
        #expect(stderr.text.contains("worktree not running"))
    }
}

@Suite("@spec ATTN-1.22: When `pane show` or `pane send` errors out due to ambiguity, unknown worktree, or missing-current-worktree, the error text shall include the literal next-step invocation the caller should run.")
struct PaneShowNextStepHintTests {
    @Test("Ambiguity hint includes the literal next command")
    func ambiguityIncludesNextCommand() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [.paneList([
            PaneInfo(id: 1, title: "zsh", focused: true),
            PaneInfo(id: 2, title: "claude", focused: false),
        ])]
        let stderr = CapturingTextSink()
        _ = PaneShowDispatcher.run(
            address: "drag-files",
            lines: 100,
            transport: transport,
            stdout: CapturingTextSink(),
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(stderr.text.contains("graftty pane show drag-files:<id>"))
    }

    @Test("Unknown-worktree error includes a 'graftty team list' next step")
    func unknownWorktreeIncludesNextCommand() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let stderr = CapturingTextSink()
        let exit = PaneShowDispatcher.run(
            address: "no-such-wt",
            lines: 100,
            transport: StubSocketTransport(), // not consulted; resolution fails first
            stdout: CapturingTextSink(),
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 1)
        #expect(stderr.text.contains("unknown worktree 'no-such-wt'"))
        #expect(stderr.text.contains("graftty team list"))
    }
}

@Suite("pane send applies same ambiguity rules as pane show")
struct PaneSendAmbiguityTests {
    @Test("Bare worktree with >1 panes prints list and exits 1")
    func multiPaneBareWtSend() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [.paneList([
            PaneInfo(id: 1, title: "zsh", focused: true),
            PaneInfo(id: 2, title: "claude", focused: false),
        ])]
        let stderr = CapturingTextSink()
        let exit = PaneSendDispatcher.run(
            address: "drag-files",
            text: "pnpm test",
            pressEnter: true,
            transport: transport,
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 1)
        #expect(stderr.text.contains("specify a pane"))
        #expect(stderr.text.contains("graftty pane send drag-files:<id>"))
    }

    @Test("Single pane bare-wt sends ok")
    func singlePaneBareWtSend() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [
            .paneList([PaneInfo(id: 1, title: "zsh", focused: true)]),
            .ok,
        ]
        let stderr = CapturingTextSink()
        let exit = PaneSendDispatcher.run(
            address: "drag-files",
            text: "pnpm test",
            pressEnter: true,
            transport: transport,
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 0)
        #expect(stderr.text.isEmpty)
    }

    @Test("Worktree-not-running error from app is surfaced verbatim")
    func sendSurfacesWorktreeNotRunning() throws {
        let stateDir = try makeTempStateWithWorktree(branch: "drag-files", path: "/tmp/wt-drag-files")
        defer { try? FileManager.default.removeItem(at: stateDir) }
        let transport = StubSocketTransport()
        transport.queue = [.error("worktree not running")]
        let stderr = CapturingTextSink()
        let exit = PaneSendDispatcher.run(
            address: "drag-files",
            text: "ls",
            pressEnter: true,
            transport: transport,
            stderr: stderr,
            stateDirectory: stateDir
        )
        #expect(exit == 1)
        #expect(stderr.text.contains("worktree not running"))
    }
}

private func makeTempStateWithWorktree(branch: String, path: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("graftty-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var state = AppState()
    state.addRepo(RepoEntry(
        path: "/tmp/repo",
        displayName: "repo",
        worktrees: [WorktreeEntry(path: path, branch: branch)]
    ))
    try state.save(to: dir)
    return dir
}

final class StubSocketTransport: SocketTransport, @unchecked Sendable {
    var queue: [ResponseMessage] = []
    func send(_ message: NotificationMessage) -> ResponseMessage {
        guard !queue.isEmpty else {
            fatalError("StubSocketTransport: queue empty for \(message)")
        }
        return queue.removeFirst()
    }
}

final class CapturingTextSink: TextSink, @unchecked Sendable {
    private(set) var text: String = ""
    func write(_ text: String) { self.text += text }
}
