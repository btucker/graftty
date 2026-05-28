#if canImport(UIKit)
import CoreGraphics
import Foundation
import GhosttyTerminal
import GrafttyProtocol
import NIOConcurrencyHelpers
import Observation
import UIKit

/// Owns one WebSocket + one libghostty InMemoryTerminalSession. Wires
/// terminal-input → binary WS out; binary WS in → terminal.receive;
/// server-announced grid → `serverGrid` (observable, for sizing);
/// first user keystroke → resize (iOS takes over leadership).
@Observable
@MainActor
public final class SessionClient {

    public let sessionName: String
    public let session: InMemoryTerminalSession

    /// The PTY's current dimensions, as reported by the server's
    /// `grid` control envelope. Nil before the first announcement
    /// arrives (WebSocket still connecting). Observers use this to
    /// size their rendering surface to match — wider than screen →
    /// horizontal scroll.
    public private(set) var serverGrid: GridSize?

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
    /// NIOLock protects `_ws` and `_wsReadyTask` which are read from
    /// nonisolated async contexts (`awaitWS`, `sendBinary`, `sendText`)
    /// while written on @MainActor (`spawnOpenTask`, `stop`).
    /// `nonisolated(unsafe)` is safe here because all reads and writes
    /// go through the `stateLock`-guarded accessors; the lock is the
    /// actual synchronization contract, not Swift's actor isolation.
    nonisolated private let stateLock = NIOLock()
    @ObservationIgnored
    nonisolated(unsafe) private var _ws: WebSocketClient?
    /// Pending open of the current/next WS. `sendBinary` / `sendText`
    /// await this so writes emitted before the factory resolves don't
    /// silently drop. Replaced on every reconnect; nil while stopped or
    /// before `start()` has run.
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
    /// Resent to the server on first keystroke to claim leadership.
    /// `@ObservationIgnored` — hot-path bookkeeping written on every
    /// layout tick; no view reads it, so don't churn observers.
    @ObservationIgnored
    private var lastIOSViewport: (cols: UInt16, rows: UInt16)?
    /// Set to `true` when a gesture or keystroke called
    /// `claimLeadershipIfNeeded()` before `lastIOSViewport` was populated
    /// by libghostty's first `onResize`. The next successful
    /// `handleViewport` flushes this and re-attempts the claim so the
    /// gesture is not silently lost. IOS-6.13 (refinement of IOS-6.5).
    @ObservationIgnored
    private var pendingLeadershipClaim: Bool = false
    /// True once we've sent the first leadership-claim event for this
    /// session (keystroke / pinch / long-press). From then on,
    /// libghostty's layout-driven resize events are forwarded to the
    /// server. Before the first claim, layout-driven resize callbacks
    /// drive only the non-leader auto-fit path (IOS-5.6), which shrinks
    /// the iOS font to fit `serverCols`; iOS does not send resize
    /// frames to the server while still non-leader.
    public private(set) var isSizeLeader: Bool = false

    nonisolated private static let lf = Data([0x0A])
    nonisolated private static let cr = Data([0x0D])

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
    /// read-only thumbnails. They must never claim PTY size-leadership,
    /// because doing so converts every libghostty viewport tick into a
    /// `WebControlEnvelope.resize` frame and creates a font-size
    /// feedback loop with the server's reported `serverGrid.cols`.
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
        // Keystroke path: user-typed bytes go straight onto the WS
        // from the callback's own context (ws.send is thread-safe).
        // First keystroke also claims leadership. IOS-6.3: a standalone
        // LF is the soft-keyboard Return; translate to CR so TUIs see
        // "submit" rather than "insert newline."
        box.onBytes = { [weak self] data in
            guard let self else { return }
            if self.role == .preview { return }
            let isSoftReturn = data.count == 1 && data.first == 0x0A
            self.sendBinary(isSoftReturn ? Self.cr : data)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordActivity()
                self.claimLeadershipIfNeeded()
            }
        }
        // Layout path: libghostty tells us "the iOS view is now N×M".
        // We memoize, but we do NOT send to the server unless we're
        // already the leader. Before the first keystroke, the Mac
        // pane's width dictates the PTY's width and we render into a
        // scroll view sized to match.
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
        if isSizeLeader {
            sendResizeToServer(cols: cols, rows: rows)
        } else if pendingLeadershipClaim {
            // Replay the early claim that fell through because
            // lastIOSViewport was nil at the time. IOS-6.13.
            claimLeadershipIfNeeded()
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
                self.setWS(client)
                return client
            } catch {
                self.setWS(nil)
                return nil
            }
        }
        self.setWSReadyTask(task)
        return task
    }

    @MainActor
    private func startIdleWatchdog() {
        idleWatchdogTask?.cancel()
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
        recordActivity()
        sendBinary(data)
        claimLeadershipIfNeeded()
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
        recordActivity()
        sendBinary(payload)
        claimLeadershipIfNeeded()
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
        currentWS()?.close()
        setWS(nil)
    }

    public func forceReconnectNow() {
        guard !stopped else { return }
        currentWSReadyTask()?.cancel()
        setWSReadyTask(nil)
        currentWS()?.close()
        setWS(nil)
        receiveTask?.cancel()
        receiveTask = nil
        self.start()
    }

    /// Idempotent leadership claim. Called by:
    /// - the keystroke path (`box.onBytes`) — IOS-6.5
    /// - the pinch and long-press gestures on `TerminalInputContainerView` — IOS-6.5
    /// No-op when `isSizeLeader`, when the role is `.preview`, when stopped,
    /// or before libghostty has reported any viewport size (in which case the
    /// claim intent is recorded and retried at the next viewport — IOS-6.13).
    public func claimLeadershipIfNeeded() {
        guard !isSizeLeader, !stopped, role != .preview else { return }
        guard let v = lastIOSViewport else {
            // No viewport yet — record the claim intent. The first
            // `handleViewport` will replay it. IOS-6.13.
            pendingLeadershipClaim = true
            return
        }
        pendingLeadershipClaim = false
        isSizeLeader = true
        sendResizeToServer(cols: v.cols, rows: v.rows)
    }

    private func sendResizeToServer(cols: UInt16, rows: UInt16) {
        Task { [weak self] in
            guard let self else { return }
            guard let ws = await self.awaitWS() else { return }
            await ws.resize(cols: Int(cols), rows: Int(rows))
        }
    }

    nonisolated private func sendBinary(_ data: Data) {
        // Await the in-flight WS open so writes emitted before the
        // factory resolves still land. On the synchronous URL path
        // (`URLSessionWebSocketClient`) the open Task completes
        // without suspending and this is effectively a no-op; on the
        // SSH-over-WebRTC path the SSH child-channel open is genuinely
        // async and this delay is what prevents the first keystroke
        // from being silently dropped.
        Task { [weak self] in
            guard let ws = await self?.awaitWS() else { return }
            try? await ws.send(.binary(data))
        }
    }

    nonisolated private func sendText(_ text: String) {
        Task { [weak self] in
            guard let ws = await self?.awaitWS() else { return }
            try? await ws.send(.text(text))
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

    private func handleTextFrame(_ text: String) {
        guard let envelope = try? WebControlEnvelope.parse(Data(text.utf8)) else { return }
        switch envelope {
        case let .grid(cols, rows):
            serverGrid = GridSize(cols: cols, rows: rows)
        case .resize:
            // Client never receives resize; ignore.
            break
        }
    }
}
#endif
