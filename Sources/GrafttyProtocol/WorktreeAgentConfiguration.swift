import Foundation

/// @spec GIT-5.35
/// When a client creates a worktree with an agent choice and optional task description, the application shall preserve the provider and exact multiline description across transport and use the destination's default agent when the provider is omitted.
public struct WorktreeAgentConfiguration: Codable, Equatable, Sendable {
    public static let maximumPromptImageCount = 8
    public static let maximumPromptImageBytes = ImagePasteMessage.maxImageBytes

    /// nil selects the owning host's configured default.
    public var provider: String?
    public var taskDescription: String
    public var promptImages: [Data]

    public init(provider: String? = nil, taskDescription: String = "", promptImages: [Data] = []) {
        self.provider = provider
        self.taskDescription = taskDescription
        self.promptImages = promptImages
    }

    public var initialPrompt: String? {
        if !taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return taskDescription }
        return promptImages.isEmpty ? nil : "Review the attached images."
    }

    public static func promptImageSizeError(_ images: [Data]) -> String? {
        guard images.count <= maximumPromptImageCount else {
            return "Attach up to \(maximumPromptImageCount) images."
        }
        var remaining = maximumPromptImageBytes
        for image in images {
            guard image.count <= remaining else { return "Prompt images must total 10 MB or less." }
            remaining -= image.count
        }
        return nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        taskDescription = try c.decodeIfPresent(String.self, forKey: .taskDescription) ?? ""
        promptImages = try c.decodeIfPresent([Data].self, forKey: .promptImages) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encode(taskDescription, forKey: .taskDescription)
        if !promptImages.isEmpty { try c.encode(promptImages, forKey: .promptImages) }
    }

    private enum CodingKeys: String, CodingKey { case provider, taskDescription, promptImages }
}
