import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyRemoteClient

struct TerminalReceiveBufferTests {
    @Test("@spec REMOTE-9.9: When SSH terminal output accumulates before a receiver drains it, the application shall combine consecutive binary frames into batches of at most 256 KiB, preserve every byte and control-frame ordering, and deliver available output without waiting for more frames.")
    func batchesHistoryWithoutCrossingControlFrames() {
        var buffer = TerminalReceiveBuffer()
        let chunk = Data(repeating: 0x61, count: 8192)
        for _ in 0..<1000 { buffer.append(.binary(chunk)) }
        buffer.append(.text("ownership"))
        buffer.append(.binary(Data([0x1B, 0x5B])))
        buffer.append(.binary(Data([0x33, 0x31, 0x6D, 0xC3])))
        buffer.append(.binary(Data([0xA9])))

        var output = Data()
        var batches = 0
        while let frame = buffer.popFirst() {
            if case .text = frame {
                #expect(frame == .text("ownership"))
                break
            }
            guard case .binary(let bytes) = frame else { return }
            #expect(bytes.count <= 256 * 1024)
            output.append(bytes)
            batches += 1
        }
        #expect(output == Data(repeating: 0x61, count: 8192 * 1000))
        #expect(batches == 32)
        #expect(buffer.popFirst() == .binary(Data([0x1B, 0x5B, 0x33, 0x31, 0x6D, 0xC3, 0xA9])))
        #expect(buffer.popFirst() == nil)
    }

    @Test func deliversSmallOutputImmediately() {
        var buffer = TerminalReceiveBuffer()
        buffer.append(.binary(Data("prompt".utf8)))
        #expect(buffer.popFirst() == .binary(Data("prompt".utf8)))
        #expect(buffer.popFirst() == nil)
        buffer.append(.text("grid"))
        buffer.append(.text("ownership"))
        #expect(buffer.popFirst() == .text("grid"))
        #expect(buffer.popFirst() == .text("ownership"))
    }

    @Test func splitsOversizedFramesWithoutLosingTheirSuffix() {
        var buffer = TerminalReceiveBuffer()
        let limit = 256 * 1024
        buffer.append(.binary(Data(repeating: 0x62, count: limit + 3)))
        buffer.append(.binary(Data([0x63])))
        buffer.append(.text("end"))
        #expect(buffer.popFirst() == .binary(Data(repeating: 0x62, count: limit)))
        #expect(buffer.popFirst() == .binary(Data([0x62, 0x62, 0x62, 0x63])))
        #expect(buffer.popFirst() == .text("end"))
        #expect(buffer.popFirst() == nil)
    }
}
