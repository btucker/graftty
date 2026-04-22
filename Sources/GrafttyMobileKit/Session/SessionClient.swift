#if canImport(UIKit)
import Foundation
import GhosttyTerminal
import GrafttyProtocol
import Observation

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

    public struct GridSize: Equatable, Hashable, Sendable {
        public let cols: UInt16
        public let rows: UInt16
    }

    private let ws: WebSocketClient
    private var receiveTask: Task<Void, Never>?
    private var stopped = false
    /// Last (cols, rows) libghostty reported for the iOS-side view.
    /// Resent to the server on first keystroke to claim leadership.
    private var lastIOSViewport: (cols: UInt16, rows: UInt16)?
    /// True once we've sent our first keystroke-triggered resize —
    /// from then on, libghostty's layout-driven resize events are
    /// forwarded to the server (iOS is the leader). Before the first
    /// keystroke, we stay silent on layout changes so the Mac pane
    /// keeps control of the PTY's dimensions.
    private var isLeader = false

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
        // First keystroke also claims leadership.
        box.onBytes = { [ws, weak self] data in
            Task { [ws] in try? await ws.send(.binary(data)) }
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
                guard let self, !self.stopped else { return }
                let cols = max(1, viewport.columns)
                let rows = max(1, viewport.rows)
                self.lastIOSViewport = (cols, rows)
                if self.isLeader {
                    self.sendResizeToServer(cols: cols, rows: rows)
                }
            }
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
        let payload = WebControlEnvelope.resize(cols: cols, rows: rows).encoded()
        Task { [ws] in try? await ws.send(.text(payload)) }
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
