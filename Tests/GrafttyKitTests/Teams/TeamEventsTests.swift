import Testing
import Foundation
@testable import GrafttyKit

@Suite("TeamChannelEvents Tests")
struct TeamChannelEventsTests {

    @Test func teamMessageEventShape() {
        let event = TeamChannelEvents.teamMessage(
            team: "acme-web",
            from: "main",
            text: "hello"
        )
        guard case let .event(type, attrs, body) = event else {
            Issue.record("expected .event variant")
            return
        }
        #expect(type == TeamChannelEvents.EventType.message)
        #expect(attrs["team"] == "acme-web")
        #expect(attrs["from"] == "main")
        #expect(body == "hello")
    }

    @Test func memberJoinedEventShape() {
        let event = TeamChannelEvents.memberJoined(
            team: "acme-web",
            member: "feature-login",
            branch: "feature/login",
            worktree: "/r/acme/.worktrees/feature-login"
        )
        guard case let .event(type, attrs, body) = event else {
            Issue.record("expected .event variant")
            return
        }
        #expect(type == TeamChannelEvents.EventType.memberJoined)
        #expect(attrs["team"] == "acme-web")
        #expect(attrs["member"] == "feature-login")
        #expect(attrs["branch"] == "feature/login")
        #expect(attrs["worktree"] == "/r/acme/.worktrees/feature-login")
        #expect(body.contains("feature-login"))
    }

    @Test func memberLeftReasonRendered() {
        let removed = TeamChannelEvents.memberLeft(team: "t", member: "m", reason: .removed)
        let exited  = TeamChannelEvents.memberLeft(team: "t", member: "m", reason: .exited)
        guard case let .event(_, removedAttrs, _) = removed,
              case let .event(_, exitedAttrs, _) = exited else {
            Issue.record("expected .event variants")
            return
        }
        #expect(removedAttrs["reason"] == "removed")
        #expect(exitedAttrs["reason"] == "exited")
    }


}
