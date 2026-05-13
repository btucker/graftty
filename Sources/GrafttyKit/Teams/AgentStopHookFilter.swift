import Foundation

/// @spec TEAM-9.1
/// Claude Code's `Stop` hook fires for both top-level agent completions
/// *and* every subagent (Task tool) completion. The two are
/// distinguishable only by the presence of `agent_id` in the JSON the
/// runtime writes to the hook's stdin — present means subagent context,
/// absent means top-level agent. `SubagentStop` is a separate event,
/// but graftty only registers `Stop`, so the same handler receives both
/// and needs to disambiguate from the payload. Stop-event CLI commands
/// (`team hook`, `team watch-inbox`) call this to skip per-Stop work
/// — overlay, notification, idle-watcher spawn — that should only fire
/// when a top-level agent actually goes idle.
public enum AgentStopHookFilter {
    public static func isSubagentStop(stdinJSON: [String: Any]) -> Bool {
        stdinJSON["agent_id"] is String
    }
}
