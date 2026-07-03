import Foundation
import Testing
@testable import GrafttyKit

@Suite("Flow State CLI rendering")
struct FlowStateCLIRenderingTests {
    @Test("@spec FLOW-3.3: `graftty flow recommend` shall render the latest recommendation as JSON by default so agents can consume it without scraping prose.")
    func recommendationJSONRenders() throws {
        let envelope = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(
                worktreeRef: "repo:feature",
                intent: .stay,
                title: "Stay",
                reason: "Because",
                confidence: .medium
            )
        )
        let text = try FlowCLIOutput.recommendationJSON(envelope)
        #expect(text.contains("\"schemaVersion\""))
        #expect(text.contains("\"Stay\""))
        #expect(try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(text.utf8)) == envelope)
    }

    @Test("Flow context renders as Flow State JSON")
    func contextJSONRenders() throws {
        let envelope = FlowContextEnvelope(generatedAt: Date(timeIntervalSince1970: 1), worktrees: [])
        let text = try FlowCLIOutput.contextJSON(envelope)
        #expect(text.contains("\"worktrees\""))
        #expect(try JSONDecoder.flowState.decode(FlowContextEnvelope.self, from: Data(text.utf8)) == envelope)
    }

    @Test("Flow status renders a stable line")
    func statusLineRenders() {
        let line = FlowCLIOutput.statusLine(
            FlowStatus(enabled: true, running: false, promptMode: .bootstrapPrompt, message: "Needs start")
        )
        #expect(line == "enabled=true running=false promptMode=bootstrap_prompt message=Needs start")
    }
}
