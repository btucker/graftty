import Foundation
import GrafttyProtocol
import Testing

struct PagedTerminalBinaryTests {
    @Test("@spec TERM-12.61: When peers negotiate binary terminal paging, the application shall carry checkpoint and history bytes without base64 expansion while preserving their identities, limits, and complete payloads.")
    func binaryPayloadsPreserveMetadataWithoutBase64() throws {
        let checkpoint = PagedTerminalCheckpoint(incarnation: 7, id: 11, cols: 120, rows: 40,
            ready: Data(repeating: 255, count: PagedTerminalLimits.readyBytes),
            hasPrimaryHistory: true, hasAlternateHistory: false)
        let page = PagedTerminalPage(incarnation: 7, checkpointID: 11, requestID: 19,
            ordinal: 3, screen: 1, data: Data(repeating: 255, count: PagedTerminalLimits.pageBytes), complete: false)
        for (event, rawBytes) in [(PagedTerminalEvent.checkpoint(checkpoint), checkpoint.ready.count), (.page(page), page.data.count)] {
            let wire = try PagedTerminalBinary.encode(event)
            #expect(wire.count <= rawBytes + 512)
            #expect(PagedTerminalBinary.isBinary(wire))
            #expect(try PagedTerminalBinary.decode(wire) == event)
            let sliced = (Data([0]) + wire).dropFirst()
            #expect(try PagedTerminalBinary.decode(sliced) == event)
        }
        let final = PagedTerminalEvent.page(.init(incarnation: 7, checkpointID: 11, requestID: 20,
            ordinal: 4, screen: 1, data: Data(), complete: true))
        #expect(try PagedTerminalBinary.decode(PagedTerminalBinary.encode(final)) == final)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_TERMINAL_FLOW_PROBES"] != nil))
    func probeEncodingCost() throws {
        let bytes = Data((0..<PagedTerminalLimits.readyBytes).map { UInt8(truncatingIfNeeded: $0 * 73 + 31) })
        let event = PagedTerminalEvent.checkpoint(.init(incarnation: 1, id: 2, cols: 120, rows: 40,
            ready: bytes, hasPrimaryHistory: true, hasAlternateHistory: false))
        for binary in [false, true] {
            let start = ContinuousClock.now
            var wireBytes = 0
            let iterations = 50
            for _ in 0..<iterations {
                let decoded: PagedTerminalEvent?
                if binary {
                    let wire = try PagedTerminalBinary.encode(event)
                    wireBytes = wire.count
                    decoded = try PagedTerminalBinary.decode(wire)
                } else {
                    let wire = try PagedTerminalEnvelope(event: event).encoded()
                    wireBytes = wire.utf8.count
                    decoded = try PagedTerminalEnvelope.parse(wire).event
                }
                #expect(decoded == event)
            }
            let elapsed = start.duration(to: .now).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            print("[paging-codec] binary=\(binary) rawBytes=\(bytes.count) wireBytes=\(wireBytes) iterations=\(iterations) roundtripSeconds=\(seconds)")
        }
    }

    @Test("Binary paging rejects truncated headers, unknown versions, unsupported events, and invalid payloads")
    func rejectsMalformedFrames() throws {
        let page = PagedTerminalEvent.page(.init(incarnation: 1, checkpointID: 2, requestID: 3,
            ordinal: 0, screen: 0, data: Data([0, 255, 1]), complete: false))
        let wire = try PagedTerminalBinary.encode(page)
        for end in 0..<9 {
            #expect(throws: (any Error).self) { try PagedTerminalBinary.decode(Data(wire.prefix(end))) }
        }
        var version = wire
        version[4] = 255
        #expect(PagedTerminalBinary.isBinary(version))
        #expect(throws: (any Error).self) { try PagedTerminalBinary.decode(version) }
        var length = wire
        length.replaceSubrange(5..<9, with: [255, 255, 255, 255])
        #expect(throws: (any Error).self) { try PagedTerminalBinary.decode(length) }
        #expect(throws: (any Error).self) { try PagedTerminalBinary.encode(.grid(cols: 80, rows: 24)) }
        #expect(throws: (any Error).self) {
            try PagedTerminalBinary.encode(.page(.init(incarnation: 1, checkpointID: 2, requestID: 3,
                ordinal: 0, screen: 0, data: Data(), complete: false)))
        }
        #expect(throws: (any Error).self) {
            try PagedTerminalBinary.decode(wire + Data(repeating: 0, count: PagedTerminalLimits.pageBytes))
        }
        #expect(!PagedTerminalBinary.isBinary(Data("{\"terminalPaging\":1}".utf8)))
    }
}
