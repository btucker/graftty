import Testing
@testable import Graftty
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
