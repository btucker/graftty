import Foundation
import Testing
@testable import GrafttyProtocol

struct PagedTerminalTests {
    @Test func boundedCheckpointFitsExistingControlCarrier() throws {
        let checkpoint = PagedTerminalCheckpoint(
            incarnation: 1, id: 2, cols: 80, rows: 24,
            ready: Data(repeating: 0xAC, count: PagedTerminalLimits.readyBytes),
            hasPrimaryHistory: true, hasAlternateHistory: false
        )
        let envelope = PagedTerminalEnvelope(event: .checkpoint(checkpoint))
        let encoded = try envelope.encoded()
        #expect(encoded.utf8.count <= StdErrControlFraming.maxFrameLength)
        #expect(try PagedTerminalEnvelope.parse(encoded) == envelope)
    }

    @Test func rejectsUnsupportedCodecAndUnframedOutput() throws {
        let checkpoint = PagedTerminalCheckpoint(
            incarnation: 1, id: 2, codec: "different", cols: 80, rows: 24,
            ready: Data([1]), hasPrimaryHistory: true, hasAlternateHistory: false
        )
        let incompatible = try PagedTerminalEnvelope(event: .checkpoint(checkpoint)).encoded()
        #expect(throws: (any Error).self) { try PagedTerminalEnvelope.parse(incompatible) }
        let output = try PagedTerminalEnvelope(event: .output(Data("VT".utf8))).encoded()
        #expect(throws: (any Error).self) { try PagedTerminalEnvelope.parse(output) }
    }

    @Test func rejectsInvalidPageIdentityAndEmptyNonfinalPage() throws {
        for screen in [UInt16(0), UInt16(2)] {
            let page = PagedTerminalPage(
                incarnation: 1, checkpointID: 2, requestID: 3, ordinal: 0,
                screen: screen, data: Data(), complete: false
            )
            let encoded = try PagedTerminalEnvelope(event: .page(page)).encoded()
            #expect(throws: (any Error).self) { try PagedTerminalEnvelope.parse(encoded) }
        }
    }
}
