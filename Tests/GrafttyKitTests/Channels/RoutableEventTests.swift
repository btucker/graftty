import Testing
@testable import GrafttyKit

@Suite("RoutableEvent classifier")
struct RoutableEventTests {

    @Test func prStateChangedNonMergeIsState() {
        let event = RoutableEvent(channelEventType: "pr_state_changed", attrs: ["to": "open"])
        #expect(event == .prStateChanged)
    }

    @Test func prStateChangedToMergedIsMerged() {
        let event = RoutableEvent(channelEventType: "pr_state_changed", attrs: ["to": "merged"])
        #expect(event == .prMerged)
    }

    @Test func prStateChangedClosedIsState() {
        let event = RoutableEvent(channelEventType: "pr_state_changed", attrs: ["to": "closed"])
        #expect(event == .prStateChanged)
    }

    @Test func ciConclusionChangedClassifies() {
        let event = RoutableEvent(channelEventType: "ci_conclusion_changed", attrs: [:])
        #expect(event == .ciConclusionChanged)
    }

    @Test func mergeStateChangedClassifies() {
        let event = RoutableEvent(channelEventType: "merge_state_changed", attrs: [:])
        #expect(event == .mergabilityChanged)
    }

    @Test func unknownTypeReturnsNil() {
        #expect(RoutableEvent(channelEventType: "team_message", attrs: [:]) == nil)
        #expect(RoutableEvent(channelEventType: "made_up", attrs: [:]) == nil)
    }
}
