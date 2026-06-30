import Foundation
import GrafttyProtocol

public enum WebSocketFrame: Equatable {
    case text(String)
    case binary(Data)
}

public protocol WebSocketClient: AnyObject {
    var supportsWebControlTextFrames: Bool { get }
    func send(_ frame: WebSocketFrame) async throws
    /// Receives the next frame. Errors surface as thrown errors.
    func receive() async throws -> WebSocketFrame
    func close()
    /// Adjust the remote terminal's window size. URLSessionWebSocketClient
    /// sends a WebControlEnvelope text frame (/ws server intercepts).
    /// TerminalSessionClient issues an SSH window-change channel request.
    /// Default: no-op so non-PTY consumers don't have to implement.
    func resize(cols: Int, rows: Int) async
    func sendHello(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        cols: Int,
        rows: Int
    ) async
    func takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: Int, rows: Int) async
    func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async
}

public extension WebSocketClient {
    var supportsWebControlTextFrames: Bool { false }
    func resize(cols: Int, rows: Int) async {}
    func sendHello(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        cols: Int,
        rows: Int
    ) async {}
    func takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: Int, rows: Int) async {}
    func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {}
}

public final class URLSessionWebSocketClient: WebSocketClient {

    private let task: URLSessionWebSocketTask
    public var supportsWebControlTextFrames: Bool { true }

    public init(url: URL, urlSession: URLSession = .shared) {
        self.task = urlSession.webSocketTask(with: url)
        self.task.resume()
    }

    public func send(_ frame: WebSocketFrame) async throws {
        switch frame {
        case .text(let s):
            try await task.send(.string(s))
        case .binary(let data):
            try await task.send(.data(data))
        }
    }

    public func receive() async throws -> WebSocketFrame {
        let message = try await task.receive()
        switch message {
        case .string(let s): return .text(s)
        case .data(let data): return .binary(data)
        @unknown default:
            throw URLError(.badServerResponse)
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    public func resize(cols: Int, rows: Int) async {
        let payload = WebControlEnvelope.resize(cols: UInt16(cols), rows: UInt16(rows)).encoded()
        try? await send(.text(payload))
    }

    public func sendHello(
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

    public func takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: Int, rows: Int) async {
        let payload = WebControlEnvelope.takeControl(
            clientID: clientID,
            kind: kind,
            cols: UInt16(cols),
            rows: UInt16(rows)
        ).encoded()
        try? await send(.text(payload))
    }

    public func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {
        let payload = WebControlEnvelope.ownerResize(
            clientID: clientID,
            epoch: epoch,
            cols: UInt16(cols),
            rows: UInt16(rows)
        ).encoded()
        try? await send(.text(payload))
    }
}
