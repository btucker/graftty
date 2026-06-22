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
        var supportsWebControlTextFrames: Bool { true }
        var closed = false
        func send(_ frame: WebSocketFrame) async throws {
            lock.withLock { _sent.append(frame) }
        }
        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }
        func close() { closed = true }
        func sendHello(
            clientID: DisplayClientID,
            kind: DisplayClientKind,
            role: DisplayClientRole,
            visible: Bool,
            cols: Int,
            rows: Int
        ) async {
            let payload = WebControlEnvelope.hello(
                clientID: clientID,
                kind: kind,
                role: role,
                visible: visible,
                cols: UInt16(cols),
                rows: UInt16(rows)
            ).encoded()
            try? await send(.text(payload))
        }
        func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {
            let payload = WebControlEnvelope.ownerResize(
                clientID: clientID,
                epoch: epoch,
                cols: UInt16(cols),
                rows: UInt16(rows)
            ).encoded()
            try? await send(.text(payload))
        }
        func takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: Int, rows: Int) async {
            let payload = WebControlEnvelope.takeControl(
                clientID: clientID,
                kind: kind,
                cols: UInt16(cols),
                rows: UInt16(rows)
            ).encoded()
            try? await send(.text(payload))
        }
    }

    private func textFrames(_ ws: FakeWS) -> [String] {
        ws.sent.compactMap { frame in
            if case let .text(text) = frame { return text }
            return nil
        }
    }

    private func envelopes(_ ws: FakeWS) -> [WebControlEnvelope] {
        textFrames(ws).compactMap { try? WebControlEnvelope.parse(Data($0.utf8)) }
    }

    private func binaryFrames(_ ws: FakeWS) -> [Data] {
        ws.sent.compactMap { frame in
            if case let .binary(data) = frame { return data }
            return nil
        }
    }

    private func firstHelloClientID(_ ws: FakeWS) -> DisplayClientID? {
        for envelope in envelopes(ws) {
            if case let .hello(clientID, _, _, _, _, _) = envelope {
                return clientID
            }
        }
        return nil
    }

    private func ownershipSnapshot(
        sessionName: String = "s",
        ownerClientID: DisplayClientID?,
        ownerKind: DisplayClientKind?,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        epoch: UInt64 = 1
    ) throws -> DisplayOwnershipSnapshot {
        try DisplayOwnershipSnapshot(
            sessionName: sessionName,
            ownerClientID: ownerClientID,
            ownerKind: ownerKind,
            grid: DisplayGrid(cols: cols, rows: rows),
            epoch: epoch
        )
    }

    @discardableResult
    private func confirmOwner(
        _ client: SessionClient,
        ws: FakeWS,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        epoch: UInt64 = 1
    ) async throws -> DisplayClientID {
        try await Task.sleep(nanoseconds: 100_000_000)
        let clientID = try #require(firstHelloClientID(ws))
        let snapshot = try ownershipSnapshot(
            ownerClientID: clientID,
            ownerKind: .ios,
            cols: cols,
            rows: rows,
            epoch: epoch
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())
        #expect(client.isOwner)
        return clientID
    }

    private func confirmFollower(
        _ client: SessionClient,
        cols: UInt16 = 100,
        rows: UInt16 = 30,
        epoch: UInt64 = 1
    ) throws {
        let snapshot = try ownershipSnapshot(
            ownerClientID: DisplayClientID("other-client"),
            ownerKind: .web,
            cols: cols,
            rows: rows,
            epoch: epoch
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())
        #expect(client.isFollower)
    }

    @Test
    func sendingBytesFromTerminalGoesOutAsBinary() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        // Simulate libghostty surface emitting bytes.
        client.session.sendInput(Data([0x68, 0x69]))   // "hi"
        // Allow the spawned Task to run.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x68, 0x69])))
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
        try await confirmOwner(client, ws: ws)
        client.session.sendInput(Data([0x0A]))
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x0D])))
        #expect(!binaryFrames(ws).contains(Data([0x0A])))
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
        try await confirmOwner(client, ws: ws)
        client.insertNewline()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x0A])))
    }

    /// The visible return-arrow control in the terminal chrome is used as
    /// "submit" by prompt-driven TUIs, so it must send CR directly.
    @Test
    func submitReturnSendsCR() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.submitReturn()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x0D])))
    }

    @Test
    func softwareKeyboardTextSendsRawUTF8WithoutPasteWrappers() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.sendSoftwareKeyboardText("abc")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data("abc".utf8)))
        #expect(!binaryFrames(ws).contains(Data("\u{1B}[200~".utf8)))
        #expect(!binaryFrames(ws).contains(Data("\u{1B}[201~".utf8)))
    }

    @Test
    func softwareKeyboardNewlineSubmitsAsCR() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.sendSoftwareKeyboardText("\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x0D])))
        #expect(!binaryFrames(ws).contains(Data([0x0A])))
    }

    @Test
    func softwareKeyboardDeleteSendsDEL() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.deleteBackward()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x7F])))
    }

    @Test
    func terminalControlKeysSendExpectedEscapeSequences() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.sendEscape()
        client.sendTab()
        client.sendArrow(.up)
        client.sendArrow(.down)
        client.sendArrow(.left)
        client.sendArrow(.right)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x1B])))
        #expect(binaryFrames(ws).contains(Data([0x09])))
        #expect(binaryFrames(ws).contains(Data("\u{1B}[A".utf8)))
        #expect(binaryFrames(ws).contains(Data("\u{1B}[B".utf8)))
        #expect(binaryFrames(ws).contains(Data("\u{1B}[D".utf8)))
        #expect(binaryFrames(ws).contains(Data("\u{1B}[C".utf8)))
    }

    @Test
    func terminalControlCharactersSendControlBytes() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.sendControl(.c)
        client.sendControl(.d)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(Data([0x03])))
        #expect(binaryFrames(ws).contains(Data([0x04])))
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
        try await confirmOwner(client, ws: ws)
        let paste = Data([0x68, 0x0A, 0x69])   // "h\ni"
        client.session.sendInput(paste)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).contains(paste))
    }

    @Test("""
    @spec IOS-11.9: `SessionClient.sendPaste(_:)` shall wrap the payload in `ESC [ 200 ~` and `ESC [ 201 ~` and emit the wrapped sequence as a single binary WebSocket frame. The single-byte LF→CR translation of `IOS-6.3` shall not apply to this path; the payload's own line endings shall be preserved verbatim.
    """)
    func sendPasteWrapsInBracketedPasteDelimiters() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.sendPaste("hello")
        try await Task.sleep(nanoseconds: 100_000_000)

        let expected = Data("\u{1B}[200~hello\u{1B}[201~".utf8)
        #expect(binaryFrames(ws).contains(expected))
    }

    @Test
    func sendPastePreservesEmbeddedNewlinesVerbatim() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        client.sendPaste("a\nb")
        try await Task.sleep(nanoseconds: 100_000_000)

        let expected = Data("\u{1B}[200~a\nb\u{1B}[201~".utf8)
        #expect(binaryFrames(ws).contains(expected))
        // The IOS-6.3 LF→CR translation must NOT apply here.
        #expect(!binaryFrames(ws).contains(Data("\u{1B}[200~a\rb\u{1B}[201~".utf8)))
    }

    @Test
    func sendPasteSkipsEmptyPayload() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws)
        let before = binaryFrames(ws).count
        client.sendPaste("")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(binaryFrames(ws).count == before)
    }

    @Test
    func stopClosesWebSocket() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        client.stop()
        // The factory is now async, so the first WS is constructed in
        // an open Task. `stop()` flags `stopped`, the open Task sees it
        // when the factory resolves, and closes the WS without
        // assigning it to `self.ws`. Quiesce so the open Task runs.
        try await Task.sleep(nanoseconds: 50_000_000)
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
        #expect(binaryFrames(ws).isEmpty)
    }

    @Test
    func previewRoleDoesNotEmitResizeOrTakeoverOnViewportOrFirstByte() async throws {
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
        let controlAttempts = envelopes(ws).filter { envelope in
            switch envelope {
            case .resize, .ownerResize, .takeControl:
                return true
            case .hello, .grid, .ownership:
                return false
            }
        }
        #expect(controlAttempts.isEmpty)
    }

    @Test
    func sendsHelloOnOpenWithFreshInteractiveIdentity() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.handleViewport(InMemoryTerminalViewport(
            columns: 100, rows: 30,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        client.start()
        defer { client.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        guard case let .hello(clientID, kind, role, visible, cols, rows)? = envelopes(ws).first else {
            Issue.record("Expected hello text frame")
            return
        }
        #expect(!clientID.rawValue.isEmpty)
        #expect(kind == .ios)
        #expect(role == .interactive)
        #expect(visible)
        #expect(cols == 100)
        #expect(rows == 30)
    }

    /// Drives `client.lastIOSViewport` to a known `(cols, rows)` so ownership
    /// controls and owner resizes have a deterministic grid to report.
    private func primeViewport(_ client: SessionClient, columns: UInt16, rows: UInt16) {
        client.handleViewport(InMemoryTerminalViewport(
            columns: columns, rows: rows,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
    }

    @Test("Follower input attempts are blocked locally and do not send binary frames")
    func followerInputAttemptsDoNotSendBinaryFrames() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try confirmFollower(client)

        client.session.sendInput(Data([0x68]))
        client.sendSoftwareKeyboardText("abc")
        client.deleteBackward()
        client.sendEscape()
        client.sendTab()
        client.sendArrow(.up)
        client.sendControl(.c)
        client.sendPaste("paste")
        client.insertNewline()
        client.submitReturn()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(binaryFrames(ws).isEmpty)
    }

    @Test
    func explicitTakeControlSendsTakeoverWithLastViewport() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 80, rows: 24)
        try confirmFollower(client, cols: 120, rows: 40)

        client.takeControl()
        try await Task.sleep(nanoseconds: 100_000_000)

        let takeovers = envelopes(ws).compactMap { envelope -> (DisplayClientID, DisplayClientKind, UInt16, UInt16)? in
            if case let .takeControl(clientID, kind, cols, rows) = envelope {
                return (clientID, kind, cols, rows)
            }
            return nil
        }
        #expect(takeovers.count == 1)
        #expect(takeovers.first?.1 == .ios)
        #expect(takeovers.first?.2 == 80)
        #expect(takeovers.first?.3 == 24)
    }

    @Test
    func ownerlessSessionCanExplicitlyTakeControl() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 90, rows: 28)
        let snapshot = try ownershipSnapshot(
            ownerClientID: nil,
            ownerKind: nil,
            cols: 120,
            rows: 40,
            epoch: 3
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())
        #expect(client.isOwnerless)
        #expect(client.canTakeControl)

        client.takeControl()
        try await Task.sleep(nanoseconds: 100_000_000)

        let takeover = envelopes(ws).first {
            if case .takeControl = $0 { return true }
            return false
        }
        #expect(takeover == .takeControl(
            clientID: firstHelloClientID(ws) ?? DisplayClientID("missing"),
            kind: .ios,
            cols: 90,
            rows: 28
        ))
    }

    @Test
    func ownerResizeSendsOwnerResizeWithCurrentEpoch() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let clientID = try await confirmOwner(client, ws: ws, cols: 80, rows: 24, epoch: 42)

        primeViewport(client, columns: 100, rows: 30)
        try await Task.sleep(nanoseconds: 100_000_000)

        let ownerResize = envelopes(ws).first { envelope in
            if case .ownerResize = envelope { return true }
            return false
        }
        #expect(ownerResize == .ownerResize(clientID: clientID, epoch: 42, cols: 100, rows: 30))
    }

    @Test
    func ownershipTextFramesUpdateOwnershipAndAuthoritativeGrid() throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })

        client.handleTextFrame(WebControlEnvelope.grid(cols: 120, rows: 40).encoded())
        #expect(client.authoritativeGrid == SessionClient.GridSize(cols: 120, rows: 40))

        let ownerID = DisplayClientID("ios-owner")
        let snapshot = try ownershipSnapshot(
            ownerClientID: ownerID,
            ownerKind: .ios,
            cols: 90,
            rows: 28,
            epoch: 7
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())

        #expect(client.ownershipSnapshot == snapshot)
        #expect(client.isFollower)
        #expect(client.authoritativeGrid == SessionClient.GridSize(cols: 90, rows: 28))
    }

    @Test
    func previewRoleNeverOwnsOrShowsTakeover() async throws {
        let ws = FakeWS()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { ws },
            role: .preview
        )
        client.start()
        defer { client.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let clientID = try #require(firstHelloClientID(ws))
        let snapshot = try ownershipSnapshot(
            ownerClientID: clientID,
            ownerKind: .ios,
            cols: 80,
            rows: 24,
            epoch: 1
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())
        client.takeControl()
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(!client.isOwner)
        #expect(!client.canTakeControl)
        let takeoverCount = envelopes(ws).filter {
            if case .takeControl = $0 { return true }
            return false
        }.count
        #expect(takeoverCount == 0)
    }
}
#endif
