import Foundation

/// The host shown on an open worktree. People with one machine never see "This Mac".
public enum WorktreeHostLabel {
    public static func text(isLocal: Bool, hostLabel: String, projectIsOnSeveralHosts: Bool) -> String? {
        if isLocal { return projectIsOnSeveralHosts ? "This Mac" : nil }
        return hostLabel
    }
}
