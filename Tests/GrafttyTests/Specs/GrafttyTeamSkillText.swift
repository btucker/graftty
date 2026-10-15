import Foundation

/// Read canonical team guidance or a specific reference directly from source,
/// avoiding stale copies in the shared SwiftPM resource bundle.
enum GrafttyTeamSkillText {
    static func load(reference: String? = nil) throws -> String {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "Tests" {
            url.deleteLastPathComponent()
        }
        let skill = url.deletingLastPathComponent().appendingPathComponent(
            "Sources/GrafttyKit/AgentPlugins/codex/plugins/graftty/skills/graftty-team"
        )
        return try String(
            contentsOf: skill.appendingPathComponent(reference.map { "references/\($0).md" } ?? "SKILL.md"),
            encoding: .utf8
        )
    }
}
