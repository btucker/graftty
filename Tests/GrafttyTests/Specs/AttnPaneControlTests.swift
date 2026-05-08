import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("@spec ATTN-1.15: When `pane show <addr>` is invoked against a running pane, the application shall return the last `--lines` lines (default 100) of that pane's `zmx` scrollback as plain text on the CLI's stdout.")
struct PaneShowHandlerTests {
    @Test("Tails 200 lines to the requested 50")
    @MainActor
    func tails200To50() async throws {
        let body = (1...200).map { "line\($0)" }.joined(separator: "\n")
        let stubReader = StubZmxHistoryReader(output: body)
        let response = GrafttyApp.handleShowPane_forTesting(
            path: "/wt", index: 1, lines: 50,
            reader: stubReader
        )
        guard case .paneShow(let text) = response else {
            Issue.record("expected .paneShow, got \(response)")
            return
        }
        let lines = text.split(separator: "\n")
        #expect(lines.count == 50)
        #expect(lines.first == "line151")
        #expect(lines.last == "line200")
    }
}

final class StubZmxHistoryReader: ZmxHistoryReader, @unchecked Sendable {
    let output: String
    init(output: String) { self.output = output }
    func history(sessionName: String) throws -> String { output }
}
