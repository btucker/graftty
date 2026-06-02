import Testing
@testable import GrafttyKit

@Suite("@spec AGENT-1.1: parse claude agents --json + ps env into busy/idle keyed by inherited ZMX_SESSION.")
struct AgentLivenessParsingTests {
    let json = """
    [ {"pid": 100, "cwd": "/a", "kind": "interactive", "sessionId": "s1", "startedAt": 1, "status": "busy"},
      {"pid": 200, "cwd": "/b", "kind": "interactive", "sessionId": "s2", "startedAt": 1, "status": "idle"} ]
    """
    // `ps eww -o pid=,command=` style: "<pid> <cmd-and-env words>"
    let ps = """
    100 claude ZMX_SESSION=graftty-aaaa1111 GRAFTTY_SOCK=/x
    200 claude ZMX_SESSION=graftty-bbbb2222
    """

    @Test func parsesBusyIdleKeyedBySession() {
        let map = AgentLivenessParsing.liveness(agentsJSON: json, psOutput: ps)
        #expect(map["graftty-aaaa1111"] == .busy)
        #expect(map["graftty-bbbb2222"] == .idle)
    }

    @Test("@spec AGENT-1.2: a session with no ZMX_SESSION is omitted.")
    func dropsSessionsWithoutZmxSession() {
        let psNoEnv = "100 claude --some-flag\n200 claude ZMX_SESSION=graftty-bbbb2222"
        let map = AgentLivenessParsing.liveness(agentsJSON: json, psOutput: psNoEnv)
        #expect(map["graftty-bbbb2222"] == .idle)
        #expect(map.count == 1)
    }

    @Test("@spec AGENT-1.4: when two sessions share a pane, busy wins.")
    func busyWinsWithinPane() {
        let json2 = """
        [ {"pid": 100, "cwd": "/a", "kind": "interactive", "sessionId": "s1", "startedAt": 1, "status": "idle"},
          {"pid": 200, "cwd": "/a", "kind": "interactive", "sessionId": "s2", "startedAt": 1, "status": "busy"} ]
        """
        let ps2 = "100 claude ZMX_SESSION=graftty-aaaa1111\n200 claude ZMX_SESSION=graftty-aaaa1111"
        let map = AgentLivenessParsing.liveness(agentsJSON: json2, psOutput: ps2)
        #expect(map["graftty-aaaa1111"] == .busy)
    }

    @Test("@spec AGENT-2.3: malformed JSON yields an empty map, no throw.")
    func malformedJsonIsEmpty() {
        #expect(AgentLivenessParsing.liveness(agentsJSON: "not json", psOutput: ps).isEmpty)
    }
}
