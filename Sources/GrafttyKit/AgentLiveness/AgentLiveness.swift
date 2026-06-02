import Foundation

/// @spec AGENT-1.0
/// Liveness of a claude agent session as reported by `claude agents --json`.
/// The JSON exposes exactly two states; richer "needs input"/"completed"
/// states live only in the interactive Agent View, not the JSON.
public enum AgentLiveness: String, Codable, Sendable, Equatable {
    case busy
    case idle
}
