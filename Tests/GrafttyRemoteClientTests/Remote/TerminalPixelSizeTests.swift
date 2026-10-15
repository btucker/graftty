import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

@Suite("@spec IOS-4.43: When GrafttyMobile sends an owner resize, the application shall include the terminal's pixel width and height derived from its cell pixel size so the host PTY reports the phone's real pixel geometry.")
struct TerminalPixelSizeTests {
    @Test func derivesPixelsFromCellSize() {
        let size = TerminalPixelSize(
            cols: 50, rows: 40,
            cellWidthPixels: 23, cellHeightPixels: 47,
            widthPixels: 1179, heightPixels: 1900
        )
        // The grid's own pixel extent, not the view's (which includes the
        // partial-cell remainder), so width / cols is the true cell width.
        #expect(size == TerminalPixelSize(width: 1150, height: 1880))
    }

    @Test func fallsBackToViewPixelsWhenCellSizeIsUnknown() {
        let size = TerminalPixelSize(
            cols: 50, rows: 40,
            cellWidthPixels: 0, cellHeightPixels: 47,
            widthPixels: 1179, heightPixels: 1900
        )
        #expect(size == TerminalPixelSize(width: 1179, height: 1880))
    }

    @Test func clampsToWinsizeRange() {
        let size = TerminalPixelSize(
            cols: 1000, rows: 1000,
            cellWidthPixels: 100, cellHeightPixels: 100,
            widthPixels: 0, heightPixels: 0
        )
        #expect(size == TerminalPixelSize(width: .max, height: .max))
    }

    @Test func legacyClientWithoutPixelOverloadStillReceivesGrid() async {
        let ws = GridOnlyClient()
        await ws.ownerResize(
            clientID: DisplayClientID("phone"), epoch: 4, cols: 50, rows: 40,
            pixels: TerminalPixelSize(width: 1150, height: 1880)
        )
        #expect(ws.grids.count == 1)
        #expect(ws.grids.first?.cols == 50 && ws.grids.first?.rows == 40)
    }

    private final class GridOnlyClient: WebSocketClient, @unchecked Sendable {
        private let lock = NSLock()
        private var _grids: [(cols: Int, rows: Int)] = []
        var grids: [(cols: Int, rows: Int)] { lock.withLock { _grids } }
        func send(_ frame: WebSocketFrame) async throws {}
        func receive() async throws -> WebSocketFrame { throw CancellationError() }
        func close() {}
        func ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: Int, rows: Int) async {
            lock.withLock { _grids.append((cols, rows)) }
        }
    }
}
