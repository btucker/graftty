#if canImport(UIKit)
import Foundation
import GhosttyTerminal
import Testing
@testable import GrafttyMobileKit
import GrafttyProtocol

@Suite
@MainActor
struct SessionClientTests {

    final class FakeWS: WebSocketClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [WebSocketFrame] = []
        var sent: [WebSocketFrame] {
            lock.withLock { _sent }
        }
        var closed = false
        func send(_ frame: WebSocketFrame) async throws {
            lock.withLock { _sent.append(frame) }
        }
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        func close() { closed = true }
    }

    @Test
    func sendingBytesFromTerminalGoesOutAsBinary() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        // Simulate libghostty surface emitting bytes.
        client.session.sendInput(Data([0x68, 0x69]))   // "hi"
        // Allow the spawned Task to run.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x68, 0x69]))))
    }

    /// The iOS soft keyboard's Return produces LF via `UIKeyInput.insertText`,
    /// but TUIs expect CR (what a physical terminal Return sends). Without
    /// translation, Enter inserts a literal newline in the prompt rather than
    /// submitting. IOS-6.3.
    @Test("""
    @spec IOS-6.3: When the outbound keystroke pipe (`SessionClient.box.onBytes`) receives a payload consisting of exactly one LF byte (`0x0A`), the application shall translate it to a single CR byte (`0x0D`) before sending it to the server. This reconciles iOS's soft-keyboard Return — which UIKit delivers as LF via `UIKeyInput.insertText("\\n")` — with the CR convention that physical terminals send on Return and that TUIs (Claude Code, readline, etc.) interpret as "submit." Without this translation, tapping Return on the iOS keyboard inserts a literal newline into the TUI's input buffer instead of submitting the current line, and there is no way to produce a submit keystroke from the soft keyboard. The rule is narrowed to a *standalone* single-byte LF so that multi-byte payloads with embedded newlines (pastes from the clipboard, programmatic text insertion) pass through unchanged and preserve their own line structure.
    """)
    func softKeyboardReturnLFIsTranslatedToCR() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.session.sendInput(Data([0x0A]))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x0D]))))
        #expect(!ws.sent.contains(.binary(Data([0x0A]))))
    }

    /// The in-app "Newline" button has to send a literal LF — it exists
    /// precisely to reach the newline code that the keyboard's Return
    /// can no longer emit after IOS-6.3. IOS-6.4.
    @Test("""
    @spec IOS-6.4: When the user taps the terminal control bar's "Insert newline" control, the application shall send a single literal LF byte (`0x0A`) to the remote session, bypassing the `IOS-6.3` LF→CR rule via `SessionClient.insertNewline()`. This is the only way to insert a multi-line boundary into a TUI prompt from the iOS soft keyboard after Return has been reserved for submission.
    """)
    func insertNewlineSendsLiteralLF() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.insertNewline()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x0A]))))
    }

    /// The visible return-arrow control in the terminal chrome is used as
    /// "submit" by prompt-driven TUIs, so it must send CR directly.
    @Test
    func submitReturnSendsCR() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.submitReturn()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x0D]))))
    }

    @Test
    func softwareKeyboardTextSendsRawUTF8WithoutPasteWrappers() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendSoftwareKeyboardText("abc")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data("abc".utf8))))
        #expect(!ws.sent.contains(.binary(Data("\u{1B}[200~".utf8))))
        #expect(!ws.sent.contains(.binary(Data("\u{1B}[201~".utf8))))
    }

    @Test
    func softwareKeyboardNewlineSubmitsAsCR() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendSoftwareKeyboardText("\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x0D]))))
        #expect(!ws.sent.contains(.binary(Data([0x0A]))))
    }

    @Test
    func softwareKeyboardDeleteSendsDEL() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.deleteBackward()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x7F]))))
    }

    @Test
    func terminalControlKeysSendExpectedEscapeSequences() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendEscape()
        client.sendTab()
        client.sendArrow(.up)
        client.sendArrow(.down)
        client.sendArrow(.left)
        client.sendArrow(.right)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x1B]))))
        #expect(ws.sent.contains(.binary(Data([0x09]))))
        #expect(ws.sent.contains(.binary(Data("\u{1B}[A".utf8))))
        #expect(ws.sent.contains(.binary(Data("\u{1B}[B".utf8))))
        #expect(ws.sent.contains(.binary(Data("\u{1B}[D".utf8))))
        #expect(ws.sent.contains(.binary(Data("\u{1B}[C".utf8))))
    }

    @Test
    func terminalControlCharactersSendControlBytes() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendControl(.c)
        client.sendControl(.d)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(Data([0x03]))))
        #expect(ws.sent.contains(.binary(Data([0x04]))))
    }

    /// Multi-byte paste buffers with embedded LFs must pass through
    /// unchanged — the LF→CR rule only applies to a standalone Return
    /// keystroke, not to arbitrary content that happens to contain LF.
    @Test
    func multiByteBufferWithEmbeddedLFIsNotTranslated() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let paste = Data([0x68, 0x0A, 0x69])   // "h\ni"
        client.session.sendInput(paste)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.contains(.binary(paste)))
    }

    @Test("""
    @spec IOS-11.9: `SessionClient.sendPaste(_:)` shall wrap the payload in `ESC [ 200 ~` and `ESC [ 201 ~` and emit the wrapped sequence as a single binary WebSocket frame. The single-byte LF→CR translation of `IOS-6.3` shall not apply to this path; the payload's own line endings shall be preserved verbatim.
    """)
    func sendPasteWrapsInBracketedPasteDelimiters() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendPaste("hello")
        try await Task.sleep(nanoseconds: 100_000_000)

        let expected = Data("\u{1B}[200~hello\u{1B}[201~".utf8)
        #expect(ws.sent.contains(.binary(expected)))
    }

    @Test
    func sendPastePreservesEmbeddedNewlinesVerbatim() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.sendPaste("a\nb")
        try await Task.sleep(nanoseconds: 100_000_000)

        let expected = Data("\u{1B}[200~a\nb\u{1B}[201~".utf8)
        #expect(ws.sent.contains(.binary(expected)))
        // The IOS-6.3 LF→CR translation must NOT apply here.
        #expect(!ws.sent.contains(.binary(Data("\u{1B}[200~a\rb\u{1B}[201~".utf8))))
    }

    @Test
    func sendPasteSkipsEmptyPayload() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let before = ws.sent.count
        client.sendPaste("")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(ws.sent.count == before)
    }

    @Test
    func stopClosesWebSocket() {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        client.stop()
        #expect(ws.closed)
    }

    @Test
    func handleViewportCapturesCellSizeInPoints() {
        let client = SessionClient(sessionName: "s", webSocketFactory: { FakeWS() })
        client.start()
        defer { client.stop() }
        client.displayScale = 3.0
        client.handleViewport(InMemoryTerminalViewport(
            columns: 80, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 18, cellHeightPixels: 36
        ))
        #expect(client.cellWidthPoints == 6.0)
    }

    @Test
    func handleViewportIgnoresZeroCellPixelsToAvoidClobberingPriorValue() {
        // Pre-lifecycle ticks arrive with cellWidthPixels == 0. Keep the
        // last known non-zero value rather than clobbering it with noise.
        let client = SessionClient(sessionName: "s", webSocketFactory: { FakeWS() })
        client.start()
        defer { client.stop() }
        client.displayScale = 2.0
        client.handleViewport(InMemoryTerminalViewport(
            columns: 80, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 14, cellHeightPixels: 28
        ))
        #expect(client.cellWidthPoints == 7.0)
        client.handleViewport(InMemoryTerminalViewport(
            columns: 80, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 0, cellHeightPixels: 0
        ))
        #expect(client.cellWidthPoints == 7.0)
    }

    @Test("@spec IOS-4.18: While a `SessionClient` is operating as a worktree-detail pane preview (`IOS-4.10`, `IOS-4.12`), the application shall not claim PTY size-leadership. Bytes emitted by libghostty in the preview controller shall be discarded rather than forwarded to the server, and layout-driven resize callbacks shall not produce `WebControlEnvelope.resize` frames. Size-leadership remains a property exclusive to the focused fullscreen pane (`IOS-6.5`).")
    func previewRoleDoesNotForwardLibghosttyBytes() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws }, role: .preview)
        client.start()
        defer { client.stop() }
        client.session.sendInput(Data([0x68, 0x69]))
        try await Task.sleep(nanoseconds: 100_000_000)
        let anyBinary = ws.sent.contains { if case .binary = $0 { return true } else { return false } }
        #expect(!anyBinary)
    }

    @Test
    func previewRoleDoesNotEmitResizeOnViewportOrFirstByte() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws }, role: .preview)
        client.start()
        defer { client.stop() }
        client.handleViewport(InMemoryTerminalViewport(
            columns: 80, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        client.session.sendInput(Data([0x68]))
        try await Task.sleep(nanoseconds: 100_000_000)
        client.handleViewport(InMemoryTerminalViewport(
            columns: 60, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        try await Task.sleep(nanoseconds: 100_000_000)
        // sendText is only called from sendResizeToServer, so any text
        // frame would be a resize envelope.
        let anyText = ws.sent.contains { if case .text = $0 { return true } else { return false } }
        #expect(!anyText)
    }

    @Test
    func fullscreenRoleStillClaimsLeadershipAndEmitsResize() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        client.handleViewport(InMemoryTerminalViewport(
            columns: 80, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        client.session.sendInput(Data([0x68]))
        try await Task.sleep(nanoseconds: 100_000_000)
        let expected = WebControlEnvelope.resize(cols: 80, rows: 24).encoded()
        #expect(ws.sent.contains(.text(expected)))
    }

    /// Drives `client.lastIOSViewport` to a known `(cols, rows)` so a subsequent
    /// `claimLeadershipIfNeeded()` has something to report. Uses the same
    /// `handleViewport` seam other tests in this file use; that path also writes
    /// `cellWidthPoints`, but the leadership-claim tests don't care about that.
    private func primeViewport(_ client: SessionClient, columns: UInt16, rows: UInt16) {
        client.handleViewport(InMemoryTerminalViewport(
            columns: columns, rows: rows,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
    }

    @Test("@spec IOS-6.5: When the iOS client receives a leadership-claim event (the first keystroke, the first pinch-begin gesture, or the first long-press-begin gesture on the terminal pane), the client shall set `isSizeLeader = true` and send a `WebControlEnvelope.resize(cols, rows)` to the server with its last-measured viewport. A passive tap shall not claim leadership.")
    func pinchGestureClaimsLeadership() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        // Prime the viewport so the claim has something to report.
        primeViewport(client, columns: 80, rows: 24)
        #expect(!client.isSizeLeader)

        client.claimLeadershipIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.isSizeLeader)
        let expected = WebControlEnvelope.resize(cols: 80, rows: 24).encoded()
        #expect(ws.sent.contains(.text(expected)))
    }

    @Test
    func leadershipClaimIsIdempotent() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 80, rows: 24)

        client.claimLeadershipIfNeeded()
        client.claimLeadershipIfNeeded()
        client.claimLeadershipIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        let resizeCount = ws.sent.filter { frame in
            if case let .text(t) = frame { return t.contains("\"type\":\"resize\"") }
            return false
        }.count
        #expect(resizeCount == 1)
    }

    @Test
    func leadershipClaimNoOpsBeforeViewport() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        // No viewport call — claim should be a no-op.
        client.claimLeadershipIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!client.isSizeLeader)
        let resizeCount = ws.sent.filter { frame in
            if case let .text(t) = frame { return t.contains("\"type\":\"resize\"") }
            return false
        }.count
        #expect(resizeCount == 0)
    }

    @Test
    func previewRoleNeverClaimsLeadership() async throws {
        let ws = FakeWS()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { ws },
            role: .preview
        )
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 80, rows: 24)
        client.claimLeadershipIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!client.isSizeLeader)
    }

    @Test("@spec IOS-6.13 (first-frame claim resilience): when a gesture fires `claimLeadershipIfNeeded` before any viewport callback has populated `lastIOSViewport`, the claim shall be retained and re-attempted at the next viewport so the user's intentional gesture is not silently dropped.")
    func firstFrameClaimRetriesOnNextViewport() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }

        // No primeViewport call — lastIOSViewport is nil.
        client.claimLeadershipIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(!client.isSizeLeader)

        // Now the first viewport callback arrives. The pending claim should
        // re-engage and send the resize.
        primeViewport(client, columns: 100, rows: 30)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(client.isSizeLeader)
        let resizeText = ws.sent.compactMap { frame -> String? in
            if case let .text(t) = frame { return t } else { return nil }
        }.first(where: { $0.contains("\"type\":\"resize\"") })
        #expect(resizeText != nil)
    }
}
#endif
