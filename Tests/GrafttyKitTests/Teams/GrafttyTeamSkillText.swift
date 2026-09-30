import Foundation

/// The bundled `graftty-team` provider skill, read from the source tree so
/// tests never see a stale copy of the shared SwiftPM resource bundle. The
/// Claude plugin's skill is a symlink to this Codex copy.
enum GrafttyTeamSkillText {
    static func load() throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" {
            url.deleteLastPathComponent()
        }
        return try String(
            contentsOf: url.deletingLastPathComponent().appendingPathComponent(
                "Sources/GrafttyKit/AgentPlugins/codex/plugins/graftty/skills/graftty-team/SKILL.md"
            ),
            encoding: .utf8
        )
    }
}
