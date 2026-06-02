import Testing
@testable import GrafttyKit

@Suite("AgentLivenessParsing — claude agents --json + ps env into busy/idle keyed by inherited ZMX_SESSION.")
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

    @Test("""
@spec AGENT-1.1: When the registry refreshes, the application shall key each claude session's busy/idle status by the `ZMX_SESSION` it inherited from its Graftty pane.
""")
    func parsesBusyIdleKeyedBySession() {
        let map = AgentLivenessParsing.liveness(agentsJSON: json, psOutput: ps)
        #expect(map["graftty-aaaa1111"] == .busy)
        #expect(map["graftty-bbbb2222"] == .idle)
    }

    @Test("""
@spec AGENT-1.2: If a claude session reports no `ZMX_SESSION` (it is not running inside a Graftty pane), then the application shall omit it from the liveness map.
""")
    func dropsSessionsWithoutZmxSession() {
        let psNoEnv = "100 claude --some-flag\n200 claude ZMX_SESSION=graftty-bbbb2222"
        let map = AgentLivenessParsing.liveness(agentsJSON: json, psOutput: psNoEnv)
        #expect(map["graftty-bbbb2222"] == .idle)
        #expect(map.count == 1)
    }

    @Test("""
@spec AGENT-1.4: When multiple claude sessions resolve to the same pane, the application shall report that pane as busy if any of its sessions is busy.
""")
    func busyWinsWithinPane() {
        let json2 = """
        [ {"pid": 100, "cwd": "/a", "kind": "interactive", "sessionId": "s1", "startedAt": 1, "status": "idle"},
          {"pid": 200, "cwd": "/a", "kind": "interactive", "sessionId": "s2", "startedAt": 1, "status": "busy"} ]
        """
        let ps2 = "100 claude ZMX_SESSION=graftty-aaaa1111\n200 claude ZMX_SESSION=graftty-aaaa1111"
        let map = AgentLivenessParsing.liveness(agentsJSON: json2, psOutput: ps2)
        #expect(map["graftty-aaaa1111"] == .busy)
    }

    @Test("""
@spec AGENT-2.3: If the `claude agents --json` invocation fails or returns unparseable output, then the application shall produce an empty liveness map without crashing.
""")
    func malformedJsonIsEmpty() {
        #expect(AgentLivenessParsing.liveness(agentsJSON: "not json", psOutput: ps).isEmpty)
    }
}
