#if canImport(UIKit)
import CoreGraphics
import Foundation
import GhosttyTerminal
import GrafttyProtocol
import Observation
import UIKit

/// Owns one WebSocket + one libghostty InMemoryTerminalSession. Wires
/// terminal-input → takeover/queued binary WS out; binary WS in → terminal.receive;
/// server-announced ownership/grid → `authoritativeGrid` (observable, for sizing);
/// explicit takeover → ownership request. Followers render passively until
/// terminal input asks to take ownership.
@Observable
@MainActor
public final class SessionClient {

    public let sessionName: String
    public let session: InMemoryTerminalSession

    /// Legacy server grid fallback. Ownership snapshots are authoritative
    /// once received; `.grid` remains a soft fallback while connecting to
    /// older servers or before the first ownership frame arrives.
    private var legacyServerGrid: GridSize?

    public private(set) var ownershipSnapshot: DisplayOwnershipSnapshot?

    public var authoritativeGrid: GridSize? {
        if let grid = ownershipSnapshot?.grid {
            return GridSize(cols: grid.cols, rows: grid.rows)
        }
        return legacyServerGrid
    }

    /// libghostty's current cell width in SwiftUI points, derived from
    /// the viewport-resize callback's `cellWidthPixels ÷ displayScale`.
    /// Nil until the first resize tick after the UITerminalView
    /// attaches. `RootView.reconcileFontOverride` pairs this with the
    /// currently-applied font size to derive the real monospace aspect
    /// of the configured font for `TerminalWidthLayout.decide` —
    /// libghostty's measurement is more accurate than the 0.6 default
    /// aspect assumption for non-default monospace fonts. Pane-preview
    /// tiles do not consume this value (they use their own
    /// `PanePreviewFontSizing` per IOS-4.12).
    public private(set) var cellWidthPoints: CGFloat?

    public struct GridSize: Equatable, Hashable, Sendable {
        public let cols: UInt16
        public let rows: UInt16
    }

    /// Display scale used to convert libghostty's pixel-based cell
    /// metrics into SwiftUI points. Seeded from `UIScreen.main.scale`;
    /// tests inject a known value.
    @ObservationIgnored
    internal var displayScale: CGFloat = UIScreen.main.scale

    nonisolated private let webSocketFactory: @Sendable () async throws -> WebSocketClient
    nonisolated internal let clock: any Clock
    nonisolated internal let backoffSchedule: [TimeInterval]
    /// NSLock protects `_ws` and `_wsReadyTask` which are read from
    /// nonisolated async contexts (`awaitWS`, `sendBinary`)
    /// while written on @MainActor (`spawnOpenTask`, `stop`).
    /// `nonisolated(unsafe)` is safe here because all reads and writes
    /// go through the `stateLock`-guarded accessors; the lock is the
    /// actual synchronization contract, not Swift's actor isolation.
    nonisolated private let stateLock = NSLock()
    @ObservationIgnored
    nonisolated(unsafe) private var _ws: WebSocketClient?
    /// Pending open of the current/next WS. `sendBinary` awaits this
    /// so writes emitted before the factory resolves don't silently drop.
    /// Replaced on every reconnect; nil while stopped or before `start()` has run.
    @ObservationIgnored
    nonisolated(unsafe) private var _wsReadyTask: Task<WebSocketClient?, Never>?

    nonisolated private func currentWS() -> WebSocketClient? { stateLock.withLock { _ws } }
    nonisolated private func currentWSReadyTask() -> Task<WebSocketClient?, Never>? {
        stateLock.withLock { _wsReadyTask }
    }
    nonisolated private func setWS(_ value: WebSocketClient?) { stateLock.withLock { _ws = value } }
    nonisolated private func setWSReadyTask(_ value: Task<WebSocketClient?, Never>?) {
        stateLock.withLock { _wsReadyTask = value }
    }
    private var receiveTask: Task<Void, Never>?
    private var stopped = false
    /// Last (cols, rows) libghostty reported for the iOS-side view.
    /// Sent with hello/takeover and, while owner, owner resize.
    /// `@ObservationIgnored` — hot-path bookkeeping written on every
    /// layout tick; no view reads it, so don't churn observers.
    @ObservationIgnored
    private var lastIOSViewport: (cols: UInt16, rows: UInt16)?
    @ObservationIgnored
    private var displayClientID: DisplayClientID = SessionClient.makeDisplayClientID()
    @ObservationIgnored
    private var ownershipTransportMode: OwnershipTransportMode = .pending
    /// IOS-6.12: legacy (non-owner-aware) servers have no ownership
    /// arbitration, so the iOS client must not resize the shared PTY merely by
    /// connecting or laying out — that would steal the column width another
    /// attached client already set. Stays false until the user first engages
    /// (keystroke/paste); reset on every (re)connect in `spawnOpenTask`.
    @ObservationIgnored
    private var legacyEngaged = false
    @ObservationIgnored
    private var pendingInputFrames: [Data] = []
    @ObservationIgnored
    private var pendingTakeoverBaseEpoch: UInt64?
    @ObservationIgnored
    private var pendingTakeoverRequested = false

    public var isOwner: Bool {
        guard role != .preview else { return false }
        if ownershipTransportMode == .legacy {
            return true
        }
        return ownershipSnapshot?.ownerClientID == displayClientID
            && ownershipSnapshot?.ownerKind == .ios
    }

    public var isFollower: Bool {
        guard role != .preview, let snapshot = ownershipSnapshot else { return false }
        return !snapshot.isOwnerless && !isOwner
    }

    public var isOwnerless: Bool {
        guard role != .preview else { return false }
        return ownershipSnapshot?.isOwnerless == true
    }

    public var canTakeControl: Bool {
        role == .fullscreen && (isFollower || isOwnerless)
    }

    nonisolated private static let lf = Data([0x0A])
    nonisolated private static let cr = Data([0x0D])

    nonisolated private static func makeDisplayClientID() -> DisplayClientID {
        DisplayClientID(UUID().uuidString)
    }

    private enum OwnershipTransportMode: Sendable {
        case pending
        case webControl
        case legacy
    }

    public enum ArrowDirection: Sendable {
        case up
        case down
        case left
        case right
    }

    public enum ControlCharacter: Sendable {
        case c
        case d
    }

    /// IOS-4.18: pane previews on the worktree-detail screen are
    /// read-only thumbnails. They must never own a display, send input,
    /// resize, or show takeover controls.
    public enum Role: Sendable {
        case fullscreen
        case preview
    }

    public let role: Role

    public enum ConnectionState: Equatable, Sendable {
        case live
        case reconnecting(attempt: Int)
    }

    /// @spec IOS-7.4
    public private(set) var connectionState: ConnectionState = .live

    public enum RenderActivity: Equatable, Sendable {
        case active
        case idle
    }

    /// @spec IOS-10.3
    public private(set) var renderActivity: RenderActivity = .active

    /// @spec IOS-10.4: While a `SessionClient` is in `.idle`, the corresponding view shall display a static snapshot of the last live frame in place of `TerminalPaneView`, with a tap target that resumes `.active`.
    public private(set) var idleSnapshot: UIImage?

    public func setIdleSnapshot(_ image: UIImage?) {
        self.idleSnapshot = image
    }

    nonisolated internal let idleThreshold: TimeInterval
    nonisolated internal let idleCheckInterval: TimeInterval

    @ObservationIgnored
    private var lastActivityAt: Date = .distantPast

    @ObservationIgnored
    private var idleWatchdogTask: Task<Void, Never>?

    public init(
        sessionName: String,
        webSocketFactory: @Sendable @escaping () async throws -> WebSocketClient,
        clock: any Clock = SystemClock(),
        backoffSchedule: [TimeInterval] = HostController.backoffSchedule(attempts: 6),
        idleThreshold: TimeInterval = SessionClient.fullscreenIdleThreshold,
        idleCheckInterval: TimeInterval = 5,
        role: Role = .fullscreen
    ) {
        self.sessionName = sessionName
        self.webSocketFactory = webSocketFactory
        self.clock = clock
        self.backoffSchedule = backoffSchedule
        self.idleThreshold = idleThreshold
        self.idleCheckInterval = idleCheckInterval
        self.role = role
        self.lastActivityAt = clock.now

        final class Box {
            var onBytes: (@Sendable (Data) -> Void)?
            var onResize: (@Sendable (InMemoryTerminalViewport) -> Void)?
        }
        let box = Box()
        self.session = InMemoryTerminalSession(
            write: { data in box.onBytes?(data) },
            resize: { viewport in box.onResize?(viewport) }
        )
        // Keystroke path: owner-typed bytes go straight onto the WS.
        // Follower keystrokes request ownership and queue until confirmed;
        // previews still block PTY-bound input locally. IOS-6.3:
        // a standalone LF is the soft-keyboard Return; translate to CR so
        // TUIs see "submit" rather than "insert newline."
        box.onBytes = { [weak self] data in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isSoftReturn = data.count == 1 && data.first == 0x0A
                self.sendInput(isSoftReturn ? Self.cr : data)
            }
        }
        // Layout path: libghostty tells us "the iOS view is now N×M".
        // We memoize, but send owner resize only while this display is
        // the confirmed owner. Followers use the authoritative grid for
        // local font fitting without resizing the PTY.
        box.onResize = { [weak self] viewport in
            Task { @MainActor [weak self] in
                self?.handleViewport(viewport)
            }
        }
    }

    @MainActor
    internal func handleViewport(_ viewport: InMemoryTerminalViewport) {
        guard !stopped else { return }
        let cols = max(1, viewport.columns)
        let rows = max(1, viewport.rows)
        lastIOSViewport = (cols, rows)
        // Skip zero values (pre-lifecycle ticks) and same-value writes —
        // `onResize` fires per layout frame during keyboard/rotation
        // animations, and an unchanged `cellWidthPoints` write would
        // still re-fire every `@Observable` observer.
        if viewport.cellWidthPixels > 0, displayScale > 0 {
            let next = CGFloat(viewport.cellWidthPixels) / displayScale
            if cellWidthPoints != next { cellWidthPoints = next }
        }
        switch ownershipTransportMode {
        case .webControl where isOwner:
            guard let epoch = ownershipSnapshot?.epoch else { return }
            sendOwnerResizeToServer(cols: cols, rows: rows, epoch: epoch)
        case .legacy where legacyEngaged:
            sendLegacyResizeToServer(cols: cols, rows: rows)
        case .pending, .webControl, .legacy:
            break
        }
    }

    /// IOS-6.12: record the user's first interaction with a legacy session and
    /// apply the current viewport. Before this fires, layout ticks leave the
    /// shared PTY untouched so connecting doesn't steal another client's size.
    /// No-op outside `.legacy` mode (`.webControl` resizes are gated on
    /// confirmed ownership instead).
    @MainActor
    private func noteLegacyEngagement() {
        guard ownershipTransportMode == .legacy, !legacyEngaged else { return }
        legacyEngaged = true
        if let viewport = lastIOSViewport {
            sendLegacyResizeToServer(cols: viewport.cols, rows: viewport.rows)
        }
    }

    public func start() {
        lastActivityAt = clock.now
        startIdleWatchdog()
        // Eagerly install a Task that opens the first WS. Outbound
        // writes that fire between `start()` returning and the factory
        // resolving wait on `wsReadyTask` so they don't silently drop
        // their bytes — important on the SSH-over-WebRTC path where
        // opening an SSH child channel is genuinely async, and
        // preserves the in-process test contract on the URL fallback
        // path (factory there resolves without suspending so writes
        // emitted right after `start()` still land).
        let openTask = spawnOpenTask()
        receiveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var attempt = 0
            // Wait for the eagerly-spawned open Task to finish so the
            // receive loop sees a coherent `ws` snapshot.
            _ = await openTask.value
            while !self.stopped {
                if self.connectionState != .live {
                    self.connectionState = .live
                }
                do {
                    guard let ws = self.currentWS() else {
                        throw URLError(.cannotConnectToHost)
                    }
                    while !self.stopped {
                        let frame = try await ws.receive()
                        // Receiving a frame means we're truly connected;
                        // reset the backoff counter so the next failure
                        // starts again at the schedule's first entry.
                        attempt = 0
                        self.recordActivity()
                        switch frame {
                        case .binary(let data):
                            self.session.receive(data)
                        case .text(let text):
                            self.handleTextFrame(text)
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // network error — fall through to backoff
                }
                if self.stopped { return }
                let delayIndex = min(attempt, self.backoffSchedule.count - 1)
                let delay = self.backoffSchedule[delayIndex]
                attempt += 1
                self.connectionState = .reconnecting(attempt: attempt)
                do {
                    try await self.clock.sleep(for: delay)
                } catch {
                    return
                }
                if self.stopped { return }
                // Refresh `wsReadyTask` so outbound writes that fired
                // during the backoff sleep are released as soon as the
                // reconnect's WS is in place.
                let reopenTask = self.spawnOpenTask()
                _ = await reopenTask.value
            }
        }
    }

    /// Spawns a `@MainActor` Task that resolves the factory and assigns
    /// the resulting WS to `self.ws`. Stores the task in `wsReadyTask`
    /// so outbound writes (via `awaitWS()`) wait on it before sending.
    /// On factory failure, `self.ws` is left nil; the receive loop
    /// throws `cannotConnectToHost` and feeds the existing backoff
    /// path. If `stop()` ran while the factory was pending, the
    /// freshly-built WS is closed instead of being assigned so it
    /// doesn't leak past the requested shutdown.
    @MainActor
    @discardableResult
    private func spawnOpenTask() -> Task<WebSocketClient?, Never> {
        let task: Task<WebSocketClient?, Never> = Task { @MainActor [weak self] in
            guard let self else { return nil }
            do {
                let client = try await self.webSocketFactory()
                if self.stopped {
                    client.close()
                    return nil
                }
                self.displayClientID = Self.makeDisplayClientID()
                self.ownershipSnapshot = nil
                self.legacyEngaged = false
                self.clearPendingInput()
                self.ownershipTransportMode = client.supportsWebControlTextFrames ? .webControl : .legacy
                self.setWS(client)
                await self.sendHelloIfSupported(on: client)
                return client
            } catch {
                self.setWS(nil)
                return nil
            }
        }
        self.setWSReadyTask(task)
        return task
    }

    private func helloGrid() -> (cols: UInt16, rows: UInt16) {
        if let viewport = lastIOSViewport {
            return viewport
        }
        if let grid = authoritativeGrid {
            return (grid.cols, grid.rows)
        }
        return (DisplayGrid.daemonFallback.cols, DisplayGrid.daemonFallback.rows)
    }

    private func sendHelloIfSupported(on client: WebSocketClient) async {
        guard client.supportsWebControlTextFrames else { return }
        let grid = helloGrid()
        await client.sendHello(
            clientID: displayClientID,
            kind: .ios,
            role: role == .preview ? .preview : .interactive,
            visible: role != .preview,
            cols: Int(grid.cols),
            rows: Int(grid.rows)
        )
    }

    @MainActor
    private func startIdleWatchdog() {
        idleWatchdogTask?.cancel()
        guard idleThreshold.isFinite else {
            idleWatchdogTask = nil
            return
        }
        idleWatchdogTask = Task { @MainActor [weak self] in
            while let self, !self.stopped, self.renderActivity == .active {
                let elapsed = self.clock.now.timeIntervalSince(self.lastActivityAt)
                let remaining = self.idleThreshold - elapsed
                if remaining <= 0 {
                    self.renderActivity = .idle
                    return
                }
                do {
                    try await self.clock.sleep(for: remaining)
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private func recordActivity() {
        lastActivityAt = clock.now
        if renderActivity == .idle {
            renderActivity = .active
            startIdleWatchdog()
        }
    }

    public func wakeRenderer() {
        recordActivity()
    }

    @MainActor
    private func sendInput(_ data: Data) {
        guard role != .preview else { return }
        switch ownershipTransportMode {
        case .webControl where isOwner:
            recordActivity()
            sendBinary(data)
        case .webControl:
            queueInputAndRequestTakeover(data)
        case .legacy:
            noteLegacyEngagement()
            recordActivity()
            sendBinary(data)
        case .pending:
            break
        }
    }

    /// IOS-6.4: send literal LF, bypassing the IOS-6.3 translation.
    public func insertNewline() {
        sendInput(Self.lf)
    }

    /// Send a Return/Enter submit keystroke. PTYs conventionally receive
    /// CR for Return; this is distinct from inserting a literal LF.
    public func submitReturn() {
        sendInput(Self.cr)
    }

    /// Send text from the iOS software keyboard as ordinary PTY input
    /// bytes. This deliberately bypasses libghostty's `sendText` path,
    /// which treats committed text like paste input and can emit
    /// bracketed-paste wrappers (`ESC [ 200 ~` / `ESC [ 201 ~`) around
    /// normal typing.
    public func sendSoftwareKeyboardText(_ text: String) {
        guard !text.isEmpty else { return }
        if text == "\n" || text == "\r" {
            submitReturn()
            return
        }
        sendInput(Data(text.utf8))
    }

    /// IOS-11.9: send clipboard text as a single bracketed-paste frame.
    /// Bypasses the IOS-6.3 single-byte LF→CR translation — pastes are
    /// not per-keystroke input and the payload's line endings are part
    /// of the paste's meaning.
    public func sendPaste(_ text: String) {
        guard !text.isEmpty else { return }
        var payload = Data("\u{1B}[200~".utf8)
        payload.append(Data(text.utf8))
        payload.append(Data("\u{1B}[201~".utf8))
        sendInput(payload)
    }

    public func deleteBackward() {
        sendInput(Data([0x7F]))
    }

    public func sendEscape() {
        sendInput(Data([0x1B]))
    }

    public func sendTab() {
        sendInput(Data([0x09]))
    }

    public func sendArrow(_ direction: ArrowDirection) {
        let sequence: String
        switch direction {
        case .up:
            sequence = "\u{1B}[A"
        case .down:
            sequence = "\u{1B}[B"
        case .left:
            sequence = "\u{1B}[D"
        case .right:
            sequence = "\u{1B}[C"
        }
        sendInput(Data(sequence.utf8))
    }

    public func sendControl(_ character: ControlCharacter) {
        let byte: UInt8
        switch character {
        case .c:
            byte = 0x03
        case .d:
            byte = 0x04
        }
        sendInput(Data([byte]))
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        receiveTask?.cancel()
        receiveTask = nil
        currentWSReadyTask()?.cancel()
        setWSReadyTask(nil)
        idleWatchdogTask?.cancel()
        idleWatchdogTask = nil
        clearPendingInput()
        currentWS()?.close()
        setWS(nil)
        ownershipTransportMode = .pending
        ownershipSnapshot = nil
    }

    public func forceReconnectNow() {
        guard !stopped else { return }
        currentWSReadyTask()?.cancel()
        setWSReadyTask(nil)
        currentWS()?.close()
        setWS(nil)
        ownershipTransportMode = .pending
        ownershipSnapshot = nil
        clearPendingInput()
        receiveTask?.cancel()
        receiveTask = nil
        self.start()
    }

    public func takeControl() {
        guard canTakeControl else { return }
        requestTakeControl()
    }

    private func queueInputAndRequestTakeover(_ data: Data) {
        pendingInputFrames.append(data)
        recordActivity()
        requestTakeControl()
    }

    private func requestTakeControl() {
        guard !pendingTakeoverRequested, !stopped else { return }
        let grid = helloGrid()
        pendingTakeoverBaseEpoch = ownershipSnapshot?.epoch
        pendingTakeoverRequested = true
        Task { [weak self] in
            guard let self else { return }
            guard let ws = await self.awaitWS(), ws.supportsWebControlTextFrames else {
                // The takeover frame could not be sent (no live owner-aware
                // socket). Drop the latch so a later keystroke re-requests
                // instead of queueing input behind a request that never went
                // out and is never cleared until a reconnect discards it.
                await MainActor.run { self.pendingTakeoverRequested = false }
                return
            }
            await ws.takeControl(
                clientID: await MainActor.run { self.displayClientID },
                kind: .ios,
                cols: Int(grid.cols),
                rows: Int(grid.rows)
            )
        }
    }

    private func clearPendingInput() {
        pendingInputFrames.removeAll()
        pendingTakeoverBaseEpoch = nil
        pendingTakeoverRequested = false
    }

    private func flushPendingInput() {
        guard !pendingInputFrames.isEmpty else {
            clearPendingInput()
            return
        }
        let frames = pendingInputFrames
        clearPendingInput()
        sendBinaryFrames(frames)
    }

    private func sendOwnerResizeToServer(cols: UInt16, rows: UInt16, epoch: UInt64) {
        Task { [weak self] in
            guard let self else { return }
            let clientID = await MainActor.run { self.displayClientID }
            guard let ws = await self.awaitWS(), ws.supportsWebControlTextFrames else { return }
            await ws.ownerResize(
                clientID: clientID,
                epoch: epoch,
                cols: Int(cols),
                rows: Int(rows)
            )
        }
    }

    /// IOS-4.24 + ordered flush: on owner promotion, send the owner-transition
    /// resize and THEN the queued input on a single task, so the remote PTY
    /// adopts the iOS grid before the queued bytes are written. Two independent
    /// tasks (`sendOwnerResizeToServer` + `flushPendingInput`) have no ordering
    /// guarantee, so the queued keystrokes could otherwise be processed at the
    /// previous owner's grid. The web client (TerminalPane.tsx) sends these in
    /// order on its single thread; this restores the same guarantee on iOS.
    private func flushPendingInputAfterOwnerResize(cols: UInt16, rows: UInt16, epoch: UInt64) {
        let frames = pendingInputFrames
        clearPendingInput()
        let clientID = displayClientID
        Task { [weak self] in
            guard let self else { return }
            guard let ws = await self.awaitWS(), ws.supportsWebControlTextFrames else { return }
            await ws.ownerResize(clientID: clientID, epoch: epoch, cols: Int(cols), rows: Int(rows))
            for data in frames {
                try? await ws.send(.binary(data))
            }
        }
    }

    private func sendLegacyResizeToServer(cols: UInt16, rows: UInt16) {
        Task { [weak self] in
            guard let self else { return }
            guard let ws = await self.awaitWS(), !ws.supportsWebControlTextFrames else { return }
            await ws.resize(cols: Int(cols), rows: Int(rows))
        }
    }

    nonisolated private func sendBinary(_ data: Data) {
        sendBinaryFrames([data])
    }

    nonisolated private func sendBinaryFrames(_ frames: [Data]) {
        guard !frames.isEmpty else { return }
        // Await the in-flight WS open so writes emitted before the
        // factory resolves still land. On the synchronous URL path
        // (`URLSessionWebSocketClient`) the open Task completes
        // without suspending and this is effectively a no-op; on the
        // SSH-over-WebRTC path the SSH child-channel open is genuinely
        // async and this delay is what prevents the first keystroke
        // from being silently dropped.
        Task { [weak self] in
            guard let ws = await self?.awaitWS() else { return }
            for data in frames {
                try? await ws.send(.binary(data))
            }
        }
    }

    /// Wait for the currently-pending `wsReadyTask` to finish (or
    /// resolve immediately if `ws` is already set and no reconnect is
    /// pending). Returns nil if `start()` hasn't run or the factory
    /// failed.
    nonisolated private func awaitWS() async -> WebSocketClient? {
        if let pending = currentWSReadyTask() {
            return await pending.value
        }
        return currentWS()
    }

    internal func handleTextFrame(_ text: String) {
        guard let envelope = try? WebControlEnvelope.parse(Data(text.utf8)) else { return }
        switch envelope {
        case let .grid(cols, rows):
            if ownershipSnapshot == nil {
                legacyServerGrid = GridSize(cols: cols, rows: rows)
            }
        case .resize:
            // Client never receives resize; ignore.
            break
        case let .ownership(snapshot):
            // IOS-4.23: ignore reordered, stale broadcasts. The server enqueues
            // sends across threads without ordering, so an older-epoch snapshot
            // can arrive after a newer one on the same socket; applying it would
            // revert the owner/grid we already advanced past. Strict `<` — owner
            // resizes keep the same epoch, so same-epoch grid updates must apply.
            if let last = ownershipSnapshot, snapshot.epoch < last.epoch {
                break
            }
            let wasOwner = isOwner
            ownershipSnapshot = snapshot
            if isOwner {
                // IOS-4.24: when this snapshot promotes us to owner, immediately
                // push the current iOS viewport so the PTY adopts our grid now
                // rather than lingering at the previous owner's size until the
                // next layout tick (mirrors the web client's owner-transition
                // resize). Send the resize and flush the queued input on one
                // ordered task so the bytes land at the new grid, not the old.
                if !wasOwner,
                   ownershipTransportMode == .webControl,
                   let viewport = lastIOSViewport {
                    flushPendingInputAfterOwnerResize(cols: viewport.cols, rows: viewport.rows, epoch: snapshot.epoch)
                } else {
                    flushPendingInput()
                }
            } else if let baseEpoch = pendingTakeoverBaseEpoch, snapshot.epoch > baseEpoch {
                clearPendingInput()
            }
        case .hello, .takeControl, .ownerResize:
            break
        }
    }
}
#endif
