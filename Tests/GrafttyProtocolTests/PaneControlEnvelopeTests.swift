import Foundation
import Testing
@testable import GrafttyProtocol

@Suite("PaneControlRequest wire format")
struct PaneControlEnvelopeTests {

    @Test
    func splitRoundTrips() throws {
        let req: PaneControlRequest = .split(target: "session-a", direction: .right)
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test("""
@spec REMOTE-7.7: When pane-control split requests are encoded, the right/down directions shall encode as the legacy horizontal/vertical wire tokens so hosts running released builds keep decoding them, left/up shall encode as their semantic tokens, and when legacy horizontal/vertical split directions are decoded, they shall decode as right/down.
""")
    func compatEncodingAndLegacyAxes() throws {
        let expectedWireTokens: [PaneControlRequest.SplitDirection: String] = [
            .right: "horizontal",
            .down: "vertical",
            .left: "left",
            .up: "up",
        ]
        for (direction, token) in expectedWireTokens {
            let encoded = try JSONEncoder().encode(
                PaneControlRequest.split(target: "s", direction: direction)
            )
            let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["direction"] as? String == token)
        }

        let legacyHorizontal = Data(#"{"type":"split","target":"s","direction":"horizontal"}"#.utf8)
        let legacyVertical = Data(#"{"type":"split","target":"s","direction":"vertical"}"#.utf8)
        #expect(try JSONDecoder().decode(PaneControlRequest.self, from: legacyHorizontal) == .split(target: "s", direction: .right))
        #expect(try JSONDecoder().decode(PaneControlRequest.self, from: legacyVertical) == .split(target: "s", direction: .down))
    }

    @Test
    func allSemanticDirectionsRoundTrip() throws {
        for direction in PaneControlRequest.SplitDirection.allCases {
            let original = PaneControlRequest.split(target: "session", direction: direction)
            let data = try JSONEncoder().encode(original)
            #expect(try JSONDecoder().decode(PaneControlRequest.self, from: data) == original)
        }
    }

    @Test("pane intents queued behind a split rebase matching targets only")
    func rebasesMatchingPaneTargets() {
        #expect(
            PaneControlRequest.close(target: "old")
                .rebasingTarget(from: "old", to: "new")
                == .close(target: "new")
        )
        #expect(
            PaneControlRequest.resize(
                target: "other",
                direction: .right,
                amount: 4,
                viewportExtent: 900
            ).rebasingTarget(from: "old", to: "new")
                == .resize(
                    target: "other",
                    direction: .right,
                    amount: 4,
                    viewportExtent: 900
                )
        )
        #expect(
            PaneControlRequest.swap(source: "old", target: "other")
                .rebasingTarget(from: "old", to: "new")
                == .swap(source: "new", target: "other")
        )
    }

    @Test("queued close projections advance through remaining panes")
    func queuedCloseProjectionAdvances() {
        var second = PaneCloseProjection(
            target: "a",
            sessionOrder: ["a", "b", "c"]
        )
        var third = second

        second.projectClose(
            from: "a",
            to: "b",
            inheritsFocus: true
        )
        third.projectClose(
            from: "a",
            to: "b",
            inheritsFocus: true
        )
        #expect(second.target == "b")
        #expect(second.replacementTarget == "c")

        third.projectClose(
            from: second.target,
            to: second.replacementTarget,
            inheritsFocus: true
        )
        #expect(third.target == "c")
        #expect(third.replacementTarget == nil)

        var splitClose = PaneCloseProjection(
            target: "a",
            sessionOrder: ["a", "c"]
        )
        splitClose.projectSplit(
            from: "a",
            to: "b",
            direction: .right,
            inheritsFocus: true
        )
        #expect(splitClose.target == "b")
        #expect(splitClose.replacementTarget == "a")

        var middleSplitClose = PaneCloseProjection(
            target: "b",
            sessionOrder: ["a", "b", "c"]
        )
        middleSplitClose.projectSplit(
            from: "b",
            to: "d",
            direction: .right,
            inheritsFocus: true
        )
        #expect(middleSplitClose.target == "d")
        #expect(middleSplitClose.replacementTarget == "a")

        var crossGenerationClose = PaneCloseProjection(
            target: "c",
            sessionOrder: ["a", "c"]
        )
        crossGenerationClose.projectSplit(
            from: "a",
            to: "b",
            direction: .left,
            inheritsFocus: false
        )
        #expect(crossGenerationClose.target == "c")
        #expect(crossGenerationClose.replacementTarget == "b")

        var repeatedLeft = PaneCloseProjection(
            target: "a",
            sessionOrder: ["a"]
        )
        repeatedLeft.projectSplit(
            from: "a",
            to: "b",
            direction: .left,
            inheritsFocus: true
        )
        repeatedLeft.projectSplit(
            from: "b",
            to: "d",
            direction: .left,
            inheritsFocus: true
        )
        #expect(repeatedLeft.target == "d")
        #expect(repeatedLeft.replacementTarget == "b")

        var repeatedRight = PaneCloseProjection(
            target: "a",
            sessionOrder: ["a"]
        )
        repeatedRight.projectSplit(
            from: "a",
            to: "b",
            direction: .right,
            inheritsFocus: true
        )
        repeatedRight.projectSplit(
            from: "b",
            to: "d",
            direction: .right,
            inheritsFocus: true
        )
        #expect(repeatedRight.target == "d")
        #expect(repeatedRight.replacementTarget == "a")
    }

    @Test
    func closeRoundTrips() throws {
        let req: PaneControlRequest = .close(target: "session-b")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func swapRoundTrips() throws {
        let req: PaneControlRequest = .swap(source: "session-a", target: "session-c")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func equalizeRoundTrips() throws {
        let req: PaneControlRequest = .equalize(target: "session-a")
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test("""
    @spec REMOTE-13.23: Remote resize requests shall carry the viewing \
    window's axis extent so the owning Mac applies the same ratio change as \
    a local worktree, while hosts shall still decode legacy requests that \
    omit that optional extent.
    """)
    func resizeRoundTrips() throws {
        let req: PaneControlRequest = .resize(
            target: "session-a",
            direction: .left,
            amount: 24,
            viewportExtent: 1440
        )
        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(PaneControlRequest.self, from: data)
        #expect(decoded == req)
    }

    @Test
    func legacyResizeWithoutViewportExtentDecodes() throws {
        let data = Data(
            #"{"type":"resize","target":"s","direction":"horizontal","amount":4}"#
                .utf8
        )
        #expect(
            try JSONDecoder().decode(PaneControlRequest.self, from: data)
                == .resize(
                    target: "s",
                    direction: .right,
                    amount: 4,
                    viewportExtent: nil
                )
        )
    }

    @Test
    func unknownRequestTypeThrows() throws {
        let json = Data(#"{"type":"unknown-op","target":"x"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(PaneControlRequest.self, from: json)
        }
    }

    @Test
    func okResponseRoundTrips() throws {
        let resp: PaneControlResponse = .ok
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        #expect(decoded == resp)
    }

    @Test("""
    @spec REMOTE-13.22: A successful remote split shall return the exact \
    created pane session through direct and relayed pane-control responses so \
    rapid split focus never depends on coalesced snapshot leaf order.
    """)
    func splitCreatedResponseRoundTrips() throws {
        let response = PaneControlResponse.splitCreated(
            sessionName: "graftty-created"
        )
        let data = try JSONEncoder().encode(response)
        #expect(
            try JSONDecoder().decode(PaneControlResponse.self, from: data)
                == response
        )
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["ok"] as? Bool == true)
        #expect(object["createdSessionName"] as? String == "graftty-created")
    }

    @Test
    func errorResponseRoundTrips() throws {
        let resp: PaneControlResponse = .error(code: "conflict", message: "target already split")
        let data = try JSONEncoder().encode(resp)
        let decoded = try JSONDecoder().decode(PaneControlResponse.self, from: data)
        #expect(decoded == resp)
    }
}
