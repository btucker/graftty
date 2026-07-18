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
        func clearSent() {
            lock.withLock { _sent.removeAll() }
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

    final class LegacyWS: WebSocketClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [WebSocketFrame] = []
        private var _resizes: [(cols: Int, rows: Int)] = []
        var sent: [WebSocketFrame] { lock.withLock { _sent } }
        var resizes: [(cols: Int, rows: Int)] { lock.withLock { _resizes } }
        var closed = false

        func send(_ frame: WebSocketFrame) async throws {
            lock.withLock { _sent.append(frame) }
        }

        func receive() async throws -> WebSocketFrame {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw CancellationError()
        }

        func close() { closed = true }

        func resize(cols: Int, rows: Int) async {
            lock.withLock { _resizes.append((cols, rows)) }
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

    private func binaryFrames(_ ws: LegacyWS) -> [Data] {
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

    private struct UnexpectedAsyncCondition: Error, CustomStringConvertible {
        let stage: String
        let observationWindow: Duration

        var description: String {
            "Unexpectedly observed \(stage) within \(observationWindow)"
        }
    }

    private func waitUntil(
        _ stage: String,
        timeout: Duration = .seconds(5),
        interval: Duration = .milliseconds(10),
        condition: () -> Bool
    ) async throws {
        do {
            try await RemoteConnectionTestSupport.pollUntil(
                timeout: timeout,
                interval: interval,
                stage: stage
            ) {
                condition()
            }
        } catch let error as RemoteConnectionTestSupport.PollTimeout {
            if condition() { return }
            throw error
        }
    }

    /// Negative async assertions have no success event to await. Observe a
    /// short quiet window and fail as soon as the forbidden effect appears.
    private func expectNever(
        _ stage: String,
        for observationWindow: Duration = .milliseconds(100),
        interval: Duration = .milliseconds(10),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: observationWindow)
        while clock.now < deadline {
            if condition() {
                throw UnexpectedAsyncCondition(
                    stage: stage,
                    observationWindow: observationWindow
                )
            }
            try await Task.sleep(for: interval)
        }
        if condition() {
            throw UnexpectedAsyncCondition(
                stage: stage,
                observationWindow: observationWindow
            )
        }
    }

    private func waitForHelloClientID(_ ws: FakeWS) async throws -> DisplayClientID {
        try await waitUntil("the initial WebSocket hello") {
            firstHelloClientID(ws) != nil
        }
        return try #require(firstHelloClientID(ws))
    }

    private func ownershipSnapshot(
        sessionName: String = "s",
        ownerClientID: DisplayClientID?,
        ownerKind: DisplayClientKind?,
        cols: UInt16 = 80,
        rows: UInt16 = 24,
        epoch: UInt64 = 1,
        revision: UInt64 = 0
    ) throws -> DisplayOwnershipSnapshot {
        try DisplayOwnershipSnapshot(
            sessionName: sessionName,
            ownerClientID: ownerClientID,
            ownerKind: ownerKind,
            grid: DisplayGrid(cols: cols, rows: rows),
            epoch: epoch,
            revision: revision
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
        let clientID = try await waitForHelloClientID(ws)
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
        let input = Data([0x68, 0x69])   // "hi"
        client.session.sendInput(input)
        try await waitUntil("terminal input to reach the WebSocket") {
            binaryFrames(ws).contains(input)
        }
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
        try await waitUntil("soft-keyboard Return to reach the WebSocket as CR") {
            binaryFrames(ws).contains(Data([0x0D]))
        }
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
        try await waitUntil("literal newline to reach the WebSocket") {
            binaryFrames(ws).contains(Data([0x0A]))
        }
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
        try await waitUntil("submit Return to reach the WebSocket") {
            binaryFrames(ws).contains(Data([0x0D]))
        }
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
        try await waitUntil("software-keyboard text to reach the WebSocket") {
            binaryFrames(ws).contains(Data("abc".utf8))
        }
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
        try await waitUntil("software-keyboard newline to reach the WebSocket as CR") {
            binaryFrames(ws).contains(Data([0x0D]))
        }
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
        try await waitUntil("delete byte to reach the WebSocket") {
            binaryFrames(ws).contains(Data([0x7F]))
        }
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
        try await waitUntil("all terminal control keys to reach the WebSocket") {
            let frames = binaryFrames(ws)
            return frames.contains(Data([0x1B]))
                && frames.contains(Data([0x09]))
                && frames.contains(Data("\u{1B}[A".utf8))
                && frames.contains(Data("\u{1B}[B".utf8))
                && frames.contains(Data("\u{1B}[D".utf8))
                && frames.contains(Data("\u{1B}[C".utf8))
        }
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
        try await waitUntil("terminal control characters to reach the WebSocket") {
            let frames = binaryFrames(ws)
            return frames.contains(Data([0x03])) && frames.contains(Data([0x04]))
        }
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
        try await waitUntil("multi-byte input to reach the WebSocket") {
            binaryFrames(ws).contains(paste)
        }
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
        let expected = Data("\u{1B}[200~hello\u{1B}[201~".utf8)
        try await waitUntil("bracketed paste to reach the WebSocket") {
            binaryFrames(ws).contains(expected)
        }
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
        let expected = Data("\u{1B}[200~a\nb\u{1B}[201~".utf8)
        try await waitUntil("multi-line bracketed paste to reach the WebSocket") {
            binaryFrames(ws).contains(expected)
        }
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
        try await expectNever("a frame for an empty paste") {
            binaryFrames(ws).count != before
        }
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
        try await waitUntil("the stopped client's pending WebSocket to close") {
            ws.closed
        }
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

    @Test("""
    @spec IOS-4.18: While a `SessionClient` is operating as a worktree-detail pane preview (`IOS-4.10`, `IOS-4.12`), it shall identify itself with `DisplayClientRole.preview`, report `visible=false`, never claim display ownership, never forward libghostty bytes to the server, and never send takeover or `ownerResize` frames. Preview sizing shall render the authoritative grid locally; only fullscreen terminal input or an explicit fullscreen Take Control action can change the display owner.
    """)
    func previewRoleDoesNotForwardLibghosttyBytes() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws }, role: .preview)
        client.start()
        defer { client.stop() }
        _ = try await waitForHelloClientID(ws)
        client.session.sendInput(Data([0x68, 0x69]))
        try await expectNever("a preview terminal-input frame") {
            !binaryFrames(ws).isEmpty
        }
        #expect(binaryFrames(ws).isEmpty)
    }

    @Test
    func previewRoleSendsPreviewHelloAndInvisible() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws }, role: .preview)
        client.handleViewport(InMemoryTerminalViewport(
            columns: 100, rows: 30,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        client.start()
        defer { client.stop() }
        _ = try await waitForHelloClientID(ws)
        guard case let .hello(_, kind, role, visible, cols, rows)? = envelopes(ws).first else {
            Issue.record("Expected preview hello text frame")
            return
        }
        #expect(kind == .ios)
        #expect(role == .preview)
        #expect(!visible)
        #expect(cols == 100)
        #expect(rows == 30)
    }

    @Test
    func previewRoleDoesNotEmitResizeOrTakeoverOnViewportOrFirstByte() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws }, role: .preview)
        client.start()
        defer { client.stop() }
        _ = try await waitForHelloClientID(ws)
        client.handleViewport(InMemoryTerminalViewport(
            columns: 80, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        client.session.sendInput(Data([0x68]))
        client.handleViewport(InMemoryTerminalViewport(
            columns: 60, rows: 24,
            widthPixels: 0, heightPixels: 0,
            cellWidthPixels: 12, cellHeightPixels: 24
        ))
        try await expectNever("a preview resize or takeover frame") {
            envelopes(ws).contains { envelope in
                switch envelope {
                case .resize, .ownerResize, .takeControl:
                    return true
                case .hello, .grid, .ownership:
                    return false
                }
            }
        }
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
        _ = try await waitForHelloClientID(ws)
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

    @Test("Follower input attempts request takeover but do not send binary frames before confirmation")
    func followerInputAttemptsRequestTakeoverWithoutSendingBinaryFramesBeforeConfirmation() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 80, rows: 24)
        _ = try await waitForHelloClientID(ws)
        try confirmFollower(client)
        ws.clearSent()

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
        try await waitUntil("the follower's single takeover request") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }
        try await expectNever("follower binary input or a duplicate takeover before confirmation") {
            !binaryFrames(ws).isEmpty || envelopes(ws).filter {
                if case .takeControl = $0 { return true }
                return false
            }.count > 1
        }

        #expect(binaryFrames(ws).isEmpty)
        let takeovers = envelopes(ws).filter {
            if case .takeControl = $0 { return true }
            return false
        }
        #expect(takeovers.count == 1)
    }

    @Test("Follower input claims ownership and flushes queued bytes after confirmation")
    func followerInputClaimsOwnershipAndFlushesQueuedBytesAfterConfirmation() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 90, rows: 28)
        let clientID = try await waitForHelloClientID(ws)
        try confirmFollower(client, cols: 120, rows: 40, epoch: 1)
        ws.clearSent()

        client.sendSoftwareKeyboardText("a")
        client.deleteBackward()
        client.sendPaste("p")
        try await waitUntil("the follower's takeover request") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }
        try await expectNever("follower binary input or a duplicate takeover before confirmation") {
            !binaryFrames(ws).isEmpty || envelopes(ws).filter {
                if case .takeControl = $0 { return true }
                return false
            }.count > 1
        }

        #expect(binaryFrames(ws).isEmpty)
        let takeovers = envelopes(ws).filter {
            if case .takeControl = $0 { return true }
            return false
        }
        #expect(takeovers.count == 1)
        #expect(takeovers.first == .takeControl(clientID: clientID, kind: .ios, cols: 90, rows: 28))

        let owned = try ownershipSnapshot(
            ownerClientID: clientID,
            ownerKind: .ios,
            cols: 120,
            rows: 40,
            epoch: 2
        )
        client.handleTextFrame(WebControlEnvelope.ownership(owned).encoded())
        let expectedPaste = Data("\u{1B}[200~p\u{1B}[201~".utf8)
        try await waitUntil("queued follower input to flush after ownership confirmation") {
            let frames = binaryFrames(ws)
            return frames.contains(Data("a".utf8))
                && frames.contains(Data([0x7F]))
                && frames.contains(expectedPaste)
        }

        #expect(binaryFrames(ws).contains(Data("a".utf8)))
        #expect(binaryFrames(ws).contains(Data([0x7F])))
        #expect(binaryFrames(ws).contains(expectedPaste))
    }

    @Test
    func explicitTakeControlSendsTakeoverWithLastViewport() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 80, rows: 24)
        _ = try await waitForHelloClientID(ws)
        try confirmFollower(client, cols: 120, rows: 40)

        client.takeControl()
        try await waitUntil("the explicit takeover request") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }

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
        let clientID = try await waitForHelloClientID(ws)
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
        try await waitUntil("the ownerless session's takeover request") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }

        let takeover = envelopes(ws).first {
            if case .takeControl = $0 { return true }
            return false
        }
        #expect(takeover == .takeControl(
            clientID: clientID,
            kind: .ios,
            cols: 90,
            rows: 28
        ))
    }

    @Test("""
    @spec IOS-6.15: When a fullscreen iOS session reconnects after it was the display owner before suspension and the server reports the session as ownerless, the application shall automatically send `takeControl` with the current iOS viewport. It shall not auto-claim when another client owns the session, so foregrounding the phone does not steal control from a Mac/web owner that took over while the phone was away.
    """)
    func reconnectingPreviousOwnerAutomaticallyReclaimsOwnerlessSession() async throws {
        let ws = FakeWS()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { ws },
            reclaimControlOnOwnerlessConnect: true
        )
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 90, rows: 28)
        let clientID = try await waitForHelloClientID(ws)
        ws.clearSent()

        let ownerless = try ownershipSnapshot(
            ownerClientID: nil,
            ownerKind: nil,
            cols: 120,
            rows: 40,
            epoch: 3
        )
        client.handleTextFrame(WebControlEnvelope.ownership(ownerless).encoded())
        try await waitUntil("automatic ownerless-session reclaim") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }

        let takeover = envelopes(ws).first {
            if case .takeControl = $0 { return true }
            return false
        }
        #expect(takeover == .takeControl(clientID: clientID, kind: .ios, cols: 90, rows: 28))
    }

    @Test
    func reconnectingPreviousOwnerDoesNotStealFromAnotherOwner() async throws {
        let ws = FakeWS()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { ws },
            reclaimControlOnOwnerlessConnect: true
        )
        client.start()
        defer { client.stop() }
        primeViewport(client, columns: 90, rows: 28)
        _ = try await waitForHelloClientID(ws)
        ws.clearSent()

        try confirmFollower(client, cols: 120, rows: 40, epoch: 3)
        try await expectNever("automatic takeover from another active owner") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }

        let takeoverCount = envelopes(ws).filter {
            if case .takeControl = $0 { return true }
            return false
        }.count
        #expect(takeoverCount == 0)
    }

    @Test
    func reconnectReclaimWaitsForViewportBeforeTakingControl() async throws {
        let ws = FakeWS()
        let client = SessionClient(
            sessionName: "s",
            webSocketFactory: { ws },
            reclaimControlOnOwnerlessConnect: true
        )
        client.start()
        defer { client.stop() }
        let clientID = try await waitForHelloClientID(ws)
        ws.clearSent()

        let ownerless = try ownershipSnapshot(
            ownerClientID: nil,
            ownerKind: nil,
            cols: 120,
            rows: 40,
            epoch: 3
        )
        client.handleTextFrame(WebControlEnvelope.ownership(ownerless).encoded())
        try await expectNever("automatic takeover before the first viewport") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }
        #expect(envelopes(ws).filter {
            if case .takeControl = $0 { return true }
            return false
        }.isEmpty)

        primeViewport(client, columns: 90, rows: 28)
        try await waitUntil("viewport-driven ownerless-session reclaim") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }
        let takeover = envelopes(ws).first {
            if case .takeControl = $0 { return true }
            return false
        }
        #expect(takeover == .takeControl(clientID: clientID, kind: .ios, cols: 90, rows: 28))
    }

    @Test
    func ownerResizeSendsOwnerResizeWithCurrentEpoch() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let clientID = try await confirmOwner(client, ws: ws, cols: 80, rows: 24, epoch: 42)

        primeViewport(client, columns: 100, rows: 30)
        try await waitUntil("the owner resize frame") {
            envelopes(ws).contains {
                if case .ownerResize = $0 { return true }
                return false
            }
        }

        let ownerResize = envelopes(ws).first { envelope in
            if case .ownerResize = envelope { return true }
            return false
        }
        #expect(ownerResize == .ownerResize(clientID: clientID, epoch: 42, cols: 100, rows: 30))
    }

    @Test
    func legacyTransportSendsInputAndWindowChangeWithoutOwnershipSnapshot() async throws {
        let ws = LegacyWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await waitUntil("the legacy WebSocket to become ready") {
            client.isOwner
        }

        client.sendSoftwareKeyboardText("abc")
        primeViewport(client, columns: 132, rows: 44)
        try await waitUntil("legacy input and resize to reach the WebSocket") {
            binaryFrames(ws).contains(Data("abc".utf8))
                && ws.resizes.contains { $0.cols == 132 && $0.rows == 44 }
        }

        #expect(client.isOwner)
        #expect(binaryFrames(ws).contains(Data("abc".utf8)))
        #expect(ws.resizes.contains { $0.cols == 132 && $0.rows == 44 })
    }

    @Test("""
    @spec IOS-6.12: While connected to a legacy (non-owner-aware) server, the application shall not resize the remote PTY until the user first engages with the session (keystroke, paste, or control key); a mere connection or layout tick shall leave the shared PTY size untouched so an already-attached client's column width is not stolen. On first engagement it shall send the current iOS viewport as the legacy window size.
    """)
    func legacyTransportDefersResizeUntilUserEngages() async throws {
        let ws = LegacyWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await waitUntil("the legacy WebSocket to become ready") {
            client.isOwner
        }

        // Layout tick on connect, before the user has engaged — must not resize.
        primeViewport(client, columns: 132, rows: 44)
        try await expectNever("a legacy resize before user engagement") {
            !ws.resizes.isEmpty
        }
        #expect(ws.resizes.isEmpty)

        // First engagement applies the current viewport and unlocks later ticks.
        client.sendSoftwareKeyboardText("x")
        try await waitUntil("the first engaged legacy resize") {
            ws.resizes.contains { $0.cols == 132 && $0.rows == 44 }
        }
        #expect(ws.resizes.contains { $0.cols == 132 && $0.rows == 44 })

        primeViewport(client, columns: 120, rows: 40)
        try await waitUntil("the subsequent legacy resize") {
            ws.resizes.contains { $0.cols == 120 && $0.rows == 40 }
        }
        #expect(ws.resizes.contains { $0.cols == 120 && $0.rows == 40 })
    }

    @Test("""
    @spec IOS-4.23: When an ownership snapshot arrives whose epoch is older than the most recently applied snapshot, the application shall ignore it, so a reordered broadcast cannot revert the owner or grid the client already advanced past. Owner resizes keep the same epoch; an equal-epoch snapshot is applied only when its revision is not lower than the last applied (see IOS-4.27).
    """)
    func ignoresLowerEpochOwnershipSnapshot() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws, cols: 80, rows: 24, epoch: 7)
        #expect(client.isOwner)

        // A reordered, older-epoch snapshot names a different owner.
        let stale = try ownershipSnapshot(
            ownerClientID: DisplayClientID("other-client"),
            ownerKind: .web,
            cols: 80, rows: 24,
            epoch: 5
        )
        client.handleTextFrame(WebControlEnvelope.ownership(stale).encoded())

        // The stale frame was dropped — this client is still owner.
        #expect(client.isOwner)
    }

    @Test("""
    @spec IOS-4.27: When an ownership snapshot arrives with the same epoch as the last applied snapshot but a lower revision, the application shall ignore it, so a reordered same-epoch owner resize cannot roll the grid back to a stale size. A same-epoch snapshot with an equal or higher revision is still applied.
    """)
    func ignoresSameEpochLowerRevisionSnapshot() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        try await confirmOwner(client, ws: ws, cols: 80, rows: 24, epoch: 3)

        let other = DisplayClientID("other-client")
        // Follower of another owner; establish a newer same-epoch grid at revision 5.
        let newer = try ownershipSnapshot(
            ownerClientID: other, ownerKind: .web,
            cols: 120, rows: 30, epoch: 4, revision: 5
        )
        client.handleTextFrame(WebControlEnvelope.ownership(newer).encoded())
        #expect(client.ownershipSnapshot?.grid == (try DisplayGrid(cols: 120, rows: 30)))

        // A reordered SAME-epoch snapshot with a LOWER revision (stale 80x24 grid).
        let stale = try ownershipSnapshot(
            ownerClientID: other, ownerKind: .web,
            cols: 80, rows: 24, epoch: 4, revision: 4
        )
        client.handleTextFrame(WebControlEnvelope.ownership(stale).encoded())
        #expect(client.ownershipSnapshot?.grid == (try DisplayGrid(cols: 120, rows: 30)),
                "a lower-revision same-epoch snapshot must not roll the grid back")

        // A same-epoch snapshot with a HIGHER revision is still applied.
        let fresh = try ownershipSnapshot(
            ownerClientID: other, ownerKind: .web,
            cols: 160, rows: 40, epoch: 4, revision: 6
        )
        client.handleTextFrame(WebControlEnvelope.ownership(fresh).encoded())
        #expect(client.ownershipSnapshot?.grid == (try DisplayGrid(cols: 160, rows: 40)),
                "a higher-revision same-epoch snapshot must apply")
    }

    @Test("""
    @spec IOS-4.24: When an ownership snapshot promotes this client from non-owner to display owner, the application shall immediately send an `ownerResize` carrying its current iOS viewport, so the remote PTY adopts the iOS grid at the moment of takeover rather than retaining the previous owner's grid until the next layout tick.
    """)
    func becomingOwnerPushesCurrentViewport() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let clientID = try await waitForHelloClientID(ws)

        // Establish an iOS viewport while a follower of another owner.
        primeViewport(client, columns: 110, rows: 33)
        let follower = try ownershipSnapshot(
            ownerClientID: DisplayClientID("other-client"),
            ownerKind: .web,
            cols: 80, rows: 24,
            epoch: 1
        )
        client.handleTextFrame(WebControlEnvelope.ownership(follower).encoded())
        #expect(client.isFollower)

        // Now this client becomes owner at a newer epoch.
        let owned = try ownershipSnapshot(
            ownerClientID: clientID,
            ownerKind: .ios,
            cols: 80, rows: 24,
            epoch: 2
        )
        client.handleTextFrame(WebControlEnvelope.ownership(owned).encoded())
        try await waitUntil("the resize sent on owner promotion") {
            envelopes(ws).contains {
                if case .ownerResize = $0 { return true }
                return false
            }
        }

        #expect(client.isOwner)
        let ownerResize = envelopes(ws).first { envelope in
            if case .ownerResize = envelope { return true }
            return false
        }
        #expect(ownerResize == .ownerResize(clientID: clientID, epoch: 2, cols: 110, rows: 33))
    }

    @Test
    func ownershipRequiresMatchingIOSKind() async throws {
        let ws = FakeWS()
        let client = SessionClient(sessionName: "s", webSocketFactory: { ws })
        client.start()
        defer { client.stop() }
        let clientID = try await waitForHelloClientID(ws)
        let snapshot = try ownershipSnapshot(
            ownerClientID: clientID,
            ownerKind: .web,
            cols: 80,
            rows: 24,
            epoch: 9
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())

        client.sendSoftwareKeyboardText("blocked")
        primeViewport(client, columns: 100, rows: 30)
        try await waitUntil("the mismatched-kind follower's takeover request") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }
        try await expectNever("mismatched-kind follower input or owner resize") {
            !binaryFrames(ws).isEmpty || envelopes(ws).contains {
                if case .ownerResize = $0 { return true }
                return false
            }
        }

        #expect(!client.isOwner)
        #expect(client.isFollower)
        #expect(binaryFrames(ws).isEmpty)
        let ownerResizeCount = envelopes(ws).filter {
            if case .ownerResize = $0 { return true }
            return false
        }.count
        #expect(ownerResizeCount == 0)
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
        let clientID = try await waitForHelloClientID(ws)
        let snapshot = try ownershipSnapshot(
            ownerClientID: clientID,
            ownerKind: .ios,
            cols: 80,
            rows: 24,
            epoch: 1
        )
        client.handleTextFrame(WebControlEnvelope.ownership(snapshot).encoded())
        client.takeControl()
        try await expectNever("a preview takeover request") {
            envelopes(ws).contains {
                if case .takeControl = $0 { return true }
                return false
            }
        }

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
