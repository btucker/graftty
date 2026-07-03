import Foundation
import Testing
@testable import GrafttyKit

@Suite("FlowStateModels")
struct FlowStateModelsTests {
    /// @spec FLOW-1.1: When `graftty flow publish` receives a version-1 recommendation envelope with valid primary/list/action fields, the application shall decode and preserve it as Flow State's latest recommendation.
    @Test
    func validRecommendationEnvelopeDecodes() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "worktreeRef": "graftty:multi-project-assistant",
            "intent": "stay",
            "title": "Stay in graftty",
            "reason": "Same repo decisions are cheaper than switching.",
            "confidence": "medium"
          },
          "sameContext": [{
            "worktreeRef": "graftty:review-fixes",
            "title": "Review fixes",
            "reason": "Same test context.",
            "estimatedEffort": "short",
            "confidence": "high"
          }],
          "heldInterruptions": [{
            "worktreeRef": "billing-api:ci-fix",
            "title": "CI failed",
            "reason": "Important but high reload cost.",
            "holdUntil": "next_focus_break",
            "urgency": "medium"
          }],
          "resumeCards": [{
            "worktreeRef": "mobile:pairing-polish",
            "title": "Pairing polish",
            "summary": "Waiting on visual QA.",
            "nextAction": "Review screenshot.",
            "stale": false
          }],
          "proposedActions": [{
            "id": "ask-status",
            "kind": "team_status_request",
            "target": "review-fixes",
            "body": "[Flow State] Please reply with status, blocker, next action, and whether you need the human.",
            "requiresConfirmation": false
          }]
        }
        """
        let envelope = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.primary.intent == .stay)
        #expect(envelope.sameContext.first?.estimatedEffort == .short)
        #expect(envelope.heldInterruptions.first?.holdUntil == .nextFocusBreak)
        #expect(envelope.resumeCards.first?.stale == false)
        #expect(envelope.proposedActions.first?.kind == .teamStatusRequest)
    }

    @Test
    func validEstimatedEffortSymbolsDecode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "intent": "none",
            "title": "None",
            "reason": "Idle",
            "confidence": "low"
          },
          "sameContext": [
            {"title": "Deep task", "reason": "Needs reload", "estimatedEffort": "deep"},
            {"title": "Unknown task", "reason": "Unclear", "estimatedEffort": "unknown"}
          ]
        }
        """
        let envelope = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        #expect(envelope.sameContext.map(\.estimatedEffort) == [.deep, .unknown])
    }

    /// @spec FLOW-1.2: If a Flow State recommendation envelope contains an unknown enum value in any rendered or executable field, the application shall reject the publish rather than silently render incompatible state.
    @Test
    func unknownEnumValueFailsDecode() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "intent": "teleport",
            "title": "Bad",
            "reason": "Bad",
            "confidence": "medium"
          }
        }
        """
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        }
    }

    @Test
    func setupRecommendationIntentDecodes() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "intent": "setup",
            "title": "Set up Flow State",
            "reason": "Bootstrap the persistent assistant.",
            "confidence": "high"
          }
        }
        """
        let envelope = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        #expect(envelope.primary.intent == .setup)
    }

    @Test
    func holdUntilSupportsV1ValuesAndAbsoluteTimestamps() throws {
        let manualRefresh = try JSONDecoder.flowState.decode(FlowHoldUntil.self, from: Data(#""manual_refresh""#.utf8))
        #expect(manualRefresh == .manualRefresh)

        let encodedManualRefresh = try JSONEncoder.flowState.encode(FlowHoldUntil.manualRefresh)
        #expect(String(data: encodedManualRefresh, encoding: .utf8)?.contains("manual_refresh") == true)

        let nextFocusBreak = try JSONDecoder.flowState.decode(FlowHoldUntil.self, from: Data(#""next_focus_break""#.utf8))
        #expect(nextFocusBreak == .nextFocusBreak)

        let absolute = try JSONDecoder.flowState.decode(FlowHoldUntil.self, from: Data(#""2026-07-03T19:00:00Z""#.utf8))
        let expectedDate = try #require(ISO8601DateFormatter().date(from: "2026-07-03T19:00:00Z"))
        #expect(absolute == .absolute(expectedDate))
    }

    @Test
    func unsupportedHoldUntilSymbolFailsDecode() throws {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder.flowState.decode(FlowHoldUntil.self, from: Data(#""end_of_day""#.utf8))
        }
    }

    /// @spec FLOW-1.4: When a Flow State recommendation object contains unknown object fields, the application shall preserve those fields when storing and re-emitting the recommendation while ignoring them for v1 rendering.
    @Test
    func unknownObjectFieldsArePreserved() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {
            "intent": "none",
            "title": "No recommendation",
            "reason": "Idle",
            "confidence": "low",
            "futurePrimaryField": {"nested": true}
          },
          "futureTopLevelField": "keep me",
          "sameContext": [{
            "worktreeRef": "repo:feature",
            "title": "Feature",
            "reason": "Nearby",
            "futureListField": 42
          }]
        }
        """
        let decoded = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder.flowState.encode(decoded)
        let text = String(data: reencoded, encoding: .utf8) ?? ""
        #expect(text.contains("futureTopLevelField"))
        #expect(text.contains("futurePrimaryField"))
        #expect(text.contains("futureListField"))
    }

    /// @spec FLOW-1.5: Flow State shall reject recommendation envelopes with unsupported schema versions, missing required envelope fields, missing required primary fields, invalid action kinds, invalid action payloads, or unknown rendered list enum values.
    @Test
    func invalidRecommendationShapesFailDecode() throws {
        let invalidJSON: [String] = [
            #"{"schemaVersion":2,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"}}"#,
            #"{"schemaVersion":1,"primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"}}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z"}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","reason":"Idle","confidence":"low"}}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"},"proposedActions":[{"id":"x","kind":"teleport","target":"repo:feature"}]}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"},"proposedActions":[{"id":"x","kind":"team_status_request"}]}"#,
            #"{"schemaVersion":1,"generatedAt":"2026-07-03T19:00:00Z","primary":{"intent":"none","title":"None","reason":"Idle","confidence":"low"},"sameContext":[{"title":"Nearby","reason":"r","estimatedEffort":"forever","confidence":"low"}]}"#
        ]
        for json in invalidJSON {
            #expect(throws: Error.self) {
                _ = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
            }
        }
    }

    /// @spec FLOW-1.6: Flow State shall normalize omitted recommendation lists to empty arrays and default omitted resume-card stale state to false.
    @Test
    func omittedListsAndResumeStaleDefaults() throws {
        let json = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-07-03T19:00:00Z",
          "primary": {"intent": "none", "title": "None", "reason": "Idle", "confidence": "low"},
          "resumeCards": [{"title": "Resume", "summary": "s", "nextAction": "n"}]
        }
        """
        let decoded = try JSONDecoder.flowState.decode(FlowRecommendationEnvelope.self, from: Data(json.utf8))
        #expect(decoded.sameContext.isEmpty)
        #expect(decoded.heldInterruptions.isEmpty)
        #expect(decoded.proposedActions.isEmpty)
        #expect(decoded.resumeCards.first?.stale == false)
    }

    @Test
    func flowStatusUsesEnabledKeyAndDecodesLegacyAvailable() throws {
        let status = FlowStatus(enabled: true, running: false, promptMode: .systemPrompt)
        let data = try JSONEncoder.flowState.encode(status)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("\"enabled\""))
        #expect(!text.contains("\"available\""))

        let decoded = try JSONDecoder.flowState.decode(FlowStatus.self, from: data)
        #expect(decoded.enabled == true)
        #expect(decoded.running == false)
        #expect(decoded.promptMode == .systemPrompt)

        let legacy = try JSONDecoder.flowState.decode(FlowStatus.self, from: Data(#"{"available":true,"running":true}"#.utf8))
        #expect(legacy.enabled == true)
        #expect(legacy.running == true)
        #expect(legacy.promptMode == .unavailable)
    }
}
