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
        guard let data = agentsJSON.data(using: .utf8),
              let sessions = try? JSONDecoder().decode([Session].self, from: data)
        else { return [:] }

        let sessionByPID = sessionNameByPID(psOutput)
        var result: [String: AgentLiveness] = [:]
        for s in sessions {
            guard let name = sessionByPID[s.pid] else { continue }   // AGENT-1.2 / 1.3
            let live: AgentLiveness = (s.status == "busy") ? .busy : .idle
            // AGENT-1.4: busy wins when multiple sessions share a pane.
            if result[name] == .busy { continue }
            result[name] = live
        }
        return result
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
