import Foundation
import Testing
@testable import GrafttyKit

@Suite("Flow State socket protocol")
struct FlowStateProtocolTests {
    @Test("@spec FLOW-3.1: Flow State socket requests shall round-trip through NotificationMessage using stable wire type names.")
    func flowRequestsRoundTrip() throws {
        let messages: [(NotificationMessage, String)] = [
            (.flowStatus, "flow_status"),
            (.flowContext, "flow_context"),
            (.flowRecommend, "flow_recommend"),
            (
                .flowSnooze(worktreeRef: "repo:feature", until: .manualRefresh, reason: "Later"),
                "flow_snooze"
            ),
            (.flowNote(worktreeRef: "repo:feature", body: "note"), "flow_note"),
            (
                .flowSummary(FlowWorktreeSummary(
                    worktreeRef: "repo:feature",
                    updatedAt: Date(timeIntervalSince1970: 1),
                    summary: "s",
                    nextAction: "n",
                    needsHuman: true
                )),
                "flow_summary"
            ),
            (.flowPublish(rawJSON: "{\"schemaVersion\":1}"), "flow_publish"),
            (.flowRequestStatus(worktreeRef: "repo:feature", explicit: false), "flow_request_status"),
        ]
        for (message, wireType) in messages {
            let data = try JSONEncoder().encode(message)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["type"] as? String == wireType)
            if case .flowSnooze = message {
                #expect(object["until"] as? String == "manual_refresh")
            }
            let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
            #expect(decoded == message)
        }
    }

    @Test("@spec FLOW-3.2: Flow State socket responses shall round-trip through ResponseMessage with typed status, context, and recommendation payloads.")
    func flowResponsesRoundTrip() throws {
        let context = FlowContextEnvelope(generatedAt: Date(timeIntervalSince1970: 1), worktrees: [])
        let recommendation = FlowRecommendationEnvelope(
            schemaVersion: 1,
            generatedAt: Date(timeIntervalSince1970: 1),
            primary: FlowPrimaryRecommendation(
                worktreeRef: nil,
                intent: .none,
                title: "No recommendation",
                reason: "No worktrees",
                confidence: .low
            )
        )
        let responses: [(ResponseMessage, String)] = [
            (.flowStatus(FlowStatus(enabled: true, running: false, message: "Needs start")), "flow_status"),
            (.flowContext(context), "flow_context"),
            (.flowRecommendation(recommendation), "flow_recommendation"),
        ]
        for (response, wireType) in responses {
            let data = try JSONEncoder().encode(response)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["type"] as? String == wireType)
            let decoded = try JSONDecoder().decode(ResponseMessage.self, from: data)
            #expect(decoded == response)
        }
    }

    @Test("@spec FLOW-3.4: `graftty flow publish` shall send raw JSON to the app so invalid agent output can be recorded as Flow State activity while preserving the last valid recommendation.")
    func flowPublishCarriesRawJSON() throws {
        let raw = "{\"schemaVersion\":1,\"primary\":{\"intent\":\"bad\"}}"
        let data = try JSONEncoder().encode(NotificationMessage.flowPublish(rawJSON: raw))
        let decoded = try JSONDecoder().decode(NotificationMessage.self, from: data)
        #expect(decoded == .flowPublish(rawJSON: raw))
    }
}
