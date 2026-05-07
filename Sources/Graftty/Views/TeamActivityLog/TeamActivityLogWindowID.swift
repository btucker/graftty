import SwiftUI
import GrafttyKit

/// @spec TEAM-7.1
/// Routing key for the Team Activity Log `WindowGroup`. Captures the
/// team's stable inbox ID plus its display name so the window's title
/// and observer can be hydrated without a second round-trip through
/// `AppState` after `openWindow(id:value:)` resolves.
///
/// Hashable so SwiftUI uniques windows by team — opening the same team
/// twice activates the existing window rather than spawning a duplicate.
/// Codable so SwiftUI can persist + restore the window across launches.
struct TeamActivityLogWindowID: Hashable, Codable {
    /// Stable identifier — currently the team's repo path; see
    /// `TeamLookup.id(of:)` for the central convention.
    let teamID: String
    /// Display name shown in the window title bar.
    let teamName: String

    /// SwiftUI scene id for the corresponding `WindowGroup`.
    static let windowGroupID = "team-activity-log"
}

extension TeamActivityLogWindowID {
    /// Resolves the activity-log routing key for the currently-focused
    /// worktree's team, or nil when the focused selection has no team
    /// (single-worktree repo, no selection, or `agentTeamsEnabled`
    /// off). Pure function so the gating logic is unit-testable
    /// without hosting the SwiftUI menu button.
    static func focusedTeamID(
        selectedWorktreePath: String?,
        repos: [RepoEntry],
        agentTeamsEnabled: Bool
    ) -> TeamActivityLogWindowID? {
        guard agentTeamsEnabled else { return nil }
        guard let path = selectedWorktreePath else { return nil }
        guard let team = TeamLookup.team(for: path, in: repos) else { return nil }
        return TeamActivityLogWindowID(
            teamID: TeamLookup.id(of: team),
            teamName: team.repoDisplayName
        )
    }
}

/// Wraps the *Window → Team Activity Log* menu item. A small View is
/// the cleanest way to read the `\.openWindow` environment value
/// inside a `.commands { CommandGroup ... }` block — `EnvironmentValues`
/// is not available directly to a `Commands` declaration.
struct TeamActivityLogMenuButton: View {
    @Binding var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @AppStorage("agentTeamsEnabled") private var agentTeamsEnabled: Bool = false

    var body: some View {
        Button("Team Activity Log") {
            guard let id = focusedTeamID() else { return }
            openWindow(id: TeamActivityLogWindowID.windowGroupID, value: id)
        }
        .disabled(focusedTeamID() == nil)
    }

    private func focusedTeamID() -> TeamActivityLogWindowID? {
        TeamActivityLogWindowID.focusedTeamID(
            selectedWorktreePath: appState.selectedWorktreePath,
            repos: appState.repos,
            agentTeamsEnabled: agentTeamsEnabled
        )
    }
}
