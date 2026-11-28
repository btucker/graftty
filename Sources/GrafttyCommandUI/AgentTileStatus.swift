import Foundation

/// The one mark before an agent's name in a gallery tile or on its sidebar logo.
public enum AgentTileDot: Sendable, Equatable {
    /// Asking the user something: orange.
    case asking
    /// Working: a pulsing blue.
    case working
}

/// @spec LAYOUT-2.251
/// While an agent is shown as a gallery tile, the application shall show an orange dot before its name only while it asks for user input, a pulsing blue dot while it works, dim it once it has finished or while its host sleeps, and caption it with its question, else its result, else its status.
public struct AgentTileStatus: Sendable, Equatable {
    public let dot: AgentTileDot?
    /// Finished agents and agents on a sleeping host are drawn faded.
    public let isDimmed: Bool
    /// Finished agents leave the live tiles for the gallery's Finished section (LAYOUT-2.262).
    public let isFinished: Bool
    public let caption: String

    public init(needsInput: Bool, isBusy: Bool, isCompleted: Bool, isCached: Bool,
                question: String?, result: String?, statusLabel: String) {
        if isCached || isCompleted { dot = nil }
        else if needsInput { dot = .asking }
        else if isBusy { dot = .working }
        else { dot = nil }
        isDimmed = isCached || isCompleted
        isFinished = isCompleted
        let question = needsInput ? question?.nonBlank : nil
        caption = question ?? result?.nonBlank ?? statusLabel
    }
}

private extension String {
    var nonBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
