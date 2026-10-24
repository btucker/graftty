import Foundation

/// Successful lifecycle execution and Git access do not establish agent login or project test success.
public struct PreparedDevContainer: Codable, Sendable, Equatable {
    public let containerID: String
    public let workspace: String
    public let configurationPath: String
    public let configurationDigest: String
    public let remoteWorkspaceFolder: String
    public let remoteUser: String?
    public let usesRelativeGitWorktree: Bool
    public let agentReady: Bool
    public let agentSkillHome: String?
    /// Configured does not establish a live parent connection or model login.
    public let mcpConfigured: Bool?
    public init(containerID: String, workspace: String, configurationPath: String, configurationDigest: String,
                remoteWorkspaceFolder: String, remoteUser: String?, usesRelativeGitWorktree: Bool, agentSkillHome: String? = nil, mcpConfigured: Bool? = nil) {
        self.containerID = containerID; self.workspace = workspace; self.configurationPath = configurationPath
        self.configurationDigest = configurationDigest; self.remoteWorkspaceFolder = remoteWorkspaceFolder
        self.remoteUser = remoteUser; self.usesRelativeGitWorktree = usesRelativeGitWorktree; agentReady = false
        self.agentSkillHome = agentSkillHome
        self.mcpConfigured = mcpConfigured
    }
}
