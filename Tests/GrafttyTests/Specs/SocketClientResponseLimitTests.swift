import Foundation
import Testing
@testable import GrafttyCLI
import enum GrafttyKit.SocketIO

@Suite("SocketClient response limits")
struct SocketClientResponseLimitTests {
    @Test func productionResponseLimitIsSixteenMiB() {
        #expect(SocketClient.maxResponseBytes == 16 * 1024 * 1024)
    }

    @Test func oversizedReadMapsToSpecificCLIErrorBeforeDecoding() {
        do {
            _ = try SocketClient.decodeResponse(
                SocketIO.CappedRead(data: Data("partial json".utf8), exceededCap: true)
            )
            Issue.record("Expected responseTooLarge")
        } catch let error as CLIError {
            if case .responseTooLarge(let maxBytes) = error {
                #expect(maxBytes == SocketClient.maxResponseBytes)
            } else {
                Issue.record("Expected responseTooLarge, got \(error)")
            }
        } catch {
            Issue.record("Expected responseTooLarge, got \(error)")
        }
    }
}
