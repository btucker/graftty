import Foundation

/// @spec TEAM-9.1
/// Claude Code's `Stop` hook fires for both top-level agent completions
/// *and* every subagent (Task tool) completion. The two are
/// distinguishable only by the presence of `agent_id` in the JSON the
/// runtime writes to the hook's stdin — present means subagent context,
/// absent means top-level agent. `SubagentStop` is a separate event,
/// but graftty only registers `Stop`, so the same handler receives both
/// and needs to disambiguate from the payload. The Stop-event CLI command
/// (`team hook`) calls this to skip per-Stop lifecycle work that should
/// only run for a top-level agent.
public enum AgentStopHookFilter {
    public static func isSubagentStop(stdinJSON: [String: Any]) -> Bool {
        stdinJSON["agent_id"] is String
    }
    /// Codex supplies a turn ID. Claude supplies a transcript path instead;
    /// its file position distinguishes another reply even when no user-prompt
    /// hook ran (for example, a native peer notification).
    public static func turnID(stdinJSON: [String: Any]) -> String? {
        if let turnID = stdinJSON["turn_id"] as? String, !turnID.isEmpty { return turnID }
        guard let path = stdinJSON["transcript_path"] as? String, path.hasPrefix("/"),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber else { return nil }
        return "transcript:\(path):\(number):\(size)"
    }

}
