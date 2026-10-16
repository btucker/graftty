import Foundation
import Testing

@Suite("Scripted agent integration protocol")
struct AgentIntegrationProtocolTests {
    @Test("@spec TEST-1.1: When an integration client receives a scripted action, the test harness shall preserve its sequence ID, provider, operation, and parameters through JSON encoding.")
    func actionRoundTrip() throws {
        let command = AgentIntegrationCommand(id: 12, operation: "resize", provider: "codex",
            parameters: ["width": "393", "height": "852"])
        #expect(try JSONDecoder().decode(AgentIntegrationCommand.self,
            from: JSONEncoder().encode(command)) == command)
    }

    @Test("@spec TEST-1.2: If a scripted integration action names an unsupported operation, then the test harness shall reject it rather than report a successful observation.")
    func rejectsUnknownActions() {
        #expect(!AgentIntegrationCommand(id: 1, operation: "silently-pass").isSupported)
        #expect(AgentIntegrationCommand(id: 2, operation: "snapshot").isSupported)
    }

    @Test("@spec TEST-1.6: When a native integration viewport contains wrapped fixture output, the test harness shall identify its reading anchor by the first logical row label rather than by physical row count.")
    func logicalRowAnchor() {
        #expect(AgentIntegrationAnchor.first(in: "continued text\nROW-000123 short\nROW-000124 next") == "ROW-000123")
        #expect(AgentIntegrationAnchor.first(in: "no numbered content").isEmpty)
    }

    @Test("@spec TEST-1.3: When an integration action completes, the test harness shall correlate its renderer and ownership observation with the originating sequence ID.")
    func observationRoundTrip() throws {
        let observation = AgentIntegrationObservation(id: 9, client: "mobile", provider: "claude",
            values: ["text": "漢字 e\u{301}", "owner": "phone", "revision": "7"], error: nil)
        #expect(try JSONDecoder().decode(AgentIntegrationObservation.self,
            from: JSONEncoder().encode(observation)) == observation)
    }
}
