import Foundation
import GrafttyProtocol

public enum WebSocketFrame: Equatable {
    case text(String)
    case binary(Data)
}

public protocol WebSocketClient: AnyObject {
    var supportsWebControlTextFrames: Bool { get }
    var supportsPagedHistory: Bool { get }
    func send(_ frame: WebSocketFrame) async throws
    /// Receives the next frame. Errors surface as thrown errors.
    func receive() async throws -> WebSocketFrame
    func close()
    /// Adjust the remote terminal's window size. TerminalSessionClient
    /// issues an SSH window-change channel request.
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
    /// IOS-4.43: owner resize carrying the terminal's pixel size. The
    /// default drops the pixels and forwards to the grid-only variant, so
    /// conformers that predate pixel reporting keep working.
    func ownerResize(
        clientID: DisplayClientID,
        epoch: UInt64,
        cols: Int,
        rows: Int,
        pixels: TerminalPixelSize
    ) async
}

public extension WebSocketClient {
    var supportsWebControlTextFrames: Bool { false }
    var supportsPagedHistory: Bool { false }
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
    func ownerResize(
        clientID: DisplayClientID,
        epoch: UInt64,
        cols: Int,
        rows: Int,
        pixels: TerminalPixelSize
    ) async {
        await ownerResize(clientID: clientID, epoch: epoch, cols: cols, rows: rows)
    }
}
