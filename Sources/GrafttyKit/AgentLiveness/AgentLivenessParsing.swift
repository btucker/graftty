import Foundation

/// Pure transform: raw `claude agents --json` + raw `ps eww -o pid=,command=`
/// output → `[zmxSessionName: AgentLiveness]`. No I/O, no throwing — bad
/// input collapses to an empty map (@spec AGENT-2.3).
public enum AgentLivenessParsing {
    private struct Session: Decodable {
        let pid: Int
        let status: String
    }

    public static func liveness(agentsJSON: String, psOutput: String) -> [String: AgentLiveness] {
        let sessionByPID = sessionNameByPID(psOutput)
        var result: [String: AgentLiveness] = [:]
        for s in decodeSessions(agentsJSON) {
            guard let name = sessionByPID[s.pid] else { continue }   // AGENT-1.2 / 1.3
            let live: AgentLiveness = (s.status == "busy") ? .busy : .idle
            // AGENT-1.4: busy wins when multiple sessions share a pane.
            if result[name] == .busy { continue }
            result[name] = live
        }
        return result
    }

    /// PIDs of every session in `claude agents --json` (empty on bad input).
    /// Lets the poller build its `ps -p <pids>` argument without re-declaring
    /// the JSON shape — the single decode site lives here.
    public static func pids(agentsJSON: String) -> [Int] {
        decodeSessions(agentsJSON).map(\.pid)
    }

    /// Decode the `claude agents --json` array. Malformed or empty input
    /// yields an empty array so callers collapse to "no sessions" — this is
    /// the single decode site that backs the AGENT-2.3 silent-failure rule.
    private static func decodeSessions(_ agentsJSON: String) -> [Session] {
        guard let data = agentsJSON.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return [] }
        return sessions
    }

    /// Extracts `ZMX_SESSION=graftty-…` per pid from `ps eww` lines of the
    /// form "<pid> <command and env tokens>". The session token is space-free.
    private static func sessionNameByPID(_ psOutput: String) -> [Int: String] {
        var out: [Int: String] = [:]
        for line in psOutput.split(separator: "\n") {
            let tokens = line.split(separator: " ")
            guard let first = tokens.first, let pid = Int(first) else { continue }
            for token in tokens.dropFirst() where token.hasPrefix("ZMX_SESSION=") {
                out[pid] = String(token.dropFirst("ZMX_SESSION=".count))
                break
            }
        }
        return out
    }
}
