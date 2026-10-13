import Foundation
import Testing
@testable import GrafttyKit

struct ZmxReplayGridDecoderTests {
    @Test(arguments: 0...12)
    func fragmentedHeaderPreservesAllFollowingBytes(split: Int) {
        let header = Data(Array("GFTGRID1".utf8) + [10, 1, 10, 0])
        let payload = Data(Array("GFTGRID1".utf8) + [0, 255, 10, 13])
        var decoder = ZmxReplayGridDecoder()
        let first = decoder.consume(Data(header.prefix(split)))
        let second = decoder.consume(Data(header.dropFirst(split)) + payload)
        let started = [first, second].filter(\.started)
        #expect(started.count == 1)
        #expect(started.first?.grid == .init(cols: 266, rows: 10))
        #expect(first.bytes + second.bytes == payload)
        #expect(decoder.consume(header + payload).bytes == header + payload)
    }

    @Test func unknownGridKeepsLegacyOutput() {
        var decoder = ZmxReplayGridDecoder()
        let result = decoder.consume(Data(Array("GFTGRID1".utf8) + [0, 0, 0, 0]) + Data("legacy".utf8))
        #expect(result.started)
        #expect(result.grid == nil)
        #expect(result.bytes == Data("legacy".utf8))
    }

    @Test func unframedDiagnosticsAndTruncatedHeaderSurvive() {
        var decoder = ZmxReplayGridDecoder()
        #expect(decoder.consume(Data("error".utf8)).bytes == Data("error".utf8))
        var truncated = ZmxReplayGridDecoder()
        #expect(truncated.consume(Data("GFT".utf8)).bytes.isEmpty)
        #expect(truncated.consume(Data(), endOfStream: true).bytes == Data("GFT".utf8))
    }
}
