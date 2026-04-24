#if canImport(UIKit)
import CoreGraphics
import Foundation
import GhosttyTerminal
import GrafttyProtocol
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
    /// Nil until the first resize tick after the UITerminalView attaches.
    /// `RootView.terminalContent` reads this to size the ScrollView's
    /// inner frame so that libghostty's internal VT grid ends up at
    /// exactly `serverGrid.cols` — otherwise its VT parser wraps lines
    /// at (frame.width / realCellWidth), which is narrower than the
    /// server and causes visible line-wrap.
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

    nonisolated private let ws: WebSocketClient
    private var receiveTask: Task<Void, Never>?
    private var stopped = false
    /// Last (cols, rows) libghostty reported for the iOS-side view.
    /// Resent to the server on first keystroke to claim leadership.
    /// `@ObservationIgnored` — hot-path bookkeeping written on every
    /// layout tick; no view reads it, so don't churn observers.
    @ObservationIgnored
    private var lastIOSViewport: (cols: UInt16, rows: UInt16)?
    /// True once we've sent our first keystroke-triggered resize —
    /// from then on, libghostty's layout-driven resize events are
    /// forwarded to the server (iOS is the leader). Before the first
    /// keystroke, we stay silent on layout changes so the Mac pane
    /// keeps control of the PTY's dimensions.
    private var isLeader = false

    nonisolated private static let lf = Data([0x0A])
    nonisolated private static let cr = Data([0x0D])

    public init(sessionName: String, webSocket: WebSocketClient) {
        self.sessionName = sessionName
        self.ws = webSocket

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
            let isSoftReturn = data.count == 1 && data.first == 0x0A
            self?.sendBinary(isSoftReturn ? Self.cr : data)
            Task { @MainActor [weak self] in
                self?.claimLeadershipIfNeeded()
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
        if isLeader {
            sendResizeToServer(cols: cols, rows: rows)
        }
    }

    public func start() {
        receiveTask = Task { @MainActor [weak self] in
            while let self, !self.stopped {
                do {
                    let frame = try await self.ws.receive()
                    switch frame {
                    case .binary(let data):
                        self.session.receive(data)
                    case .text(let text):
                        self.handleTextFrame(text)
                    }
                } catch {
                    break
                }
            }
        }
    }

    /// IOS-6.4: send literal LF, bypassing the IOS-6.3 translation.
    public func insertNewline() {
        sendBinary(Self.lf)
        claimLeadershipIfNeeded()
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        receiveTask?.cancel()
        receiveTask = nil
        ws.close()
    }

    private func claimLeadershipIfNeeded() {
        guard !isLeader, !stopped, let v = lastIOSViewport else { return }
        isLeader = true
        sendResizeToServer(cols: v.cols, rows: v.rows)
    }

    private func sendResizeToServer(cols: UInt16, rows: UInt16) {
        sendText(WebControlEnvelope.resize(cols: cols, rows: rows).encoded())
    }

    nonisolated private func sendBinary(_ data: Data) {
        Task { [ws] in try? await ws.send(.binary(data)) }
    }

    nonisolated private func sendText(_ text: String) {
        Task { [ws] in try? await ws.send(.text(text)) }
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
