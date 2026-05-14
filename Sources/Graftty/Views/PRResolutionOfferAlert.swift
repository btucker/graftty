import Foundation
import GrafttyProtocol

/// Configuration for the GIT-4.7 "Pull request #N <resolved>"
/// offer-delete dialog. Lives in its own type — a pure value, no AppKit
/// — so the message-text and button-label rules stay testable without
/// constructing an `NSAlert` (its `init` lazy-loads a NIB that needs a
/// running `NSApplication`, which `swift test` doesn't provide). Mirrors
/// the split already used for the GIT-4.4 failure alert
/// (`ForceDeleteAlert`).
enum PRResolutionOfferAlert {
    struct Configuration: Equatable {
        var messageText: String
        var informativeText: String
        var primaryButton: String
        var secondaryButton: String
    }

    /// Returns `nil` for non-terminal states (`.open`) so the factory
    /// owns the "PR isn't done, no offer" rule rather than asking every
    /// caller to pre-guard `state.resolutionWord`.
    static func configuration(prNumber: Int, prTitle: String, state: PRInfo.State) -> Configuration? {
        guard let resolutionWord = state.resolutionWord else { return nil }
        let titlePrefix = prTitle.isEmpty ? "" : "\(prTitle)\n\n"
        return Configuration(
            messageText: "Pull request #\(prNumber) \(resolutionWord)",
            informativeText: "\(titlePrefix)Delete the worktree now? This will delete the worktree but not the branch.",
            primaryButton: "Delete Worktree",
            secondaryButton: "Keep"
        )
    }
}
