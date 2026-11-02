import Foundation

/// @spec GIT-5.35
/// When a client creates a worktree with an agent choice and optional task description, the application shall preserve the provider and exact multiline description across transport and use the destination's default agent when the provider is omitted.
public struct WorktreeAgentConfiguration: Codable, Equatable, Sendable {
    /// nil selects the owning host's configured default.
    public var provider: String?
    public var taskDescription: String

    public init(provider: String? = nil, taskDescription: String = "") {
        self.provider = provider
        self.taskDescription = taskDescription
    }

    public var initialPrompt: String? {
        taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : taskDescription
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription) ?? ""
    }

    private enum CodingKeys: String, CodingKey { case provider, taskDescription }
}
