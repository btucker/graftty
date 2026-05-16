import AppKit
import GrafttyProtocol

/// Builds the `SheetAlert.Configuration` for the GIT-4.7 "Pull request
/// #N <resolved>" offer-delete dialog. Pure value factory — no AppKit
/// alert construction here — so the message-text and button-label
/// rules stay testable without booting NSAlert (its `init` lazy-loads
/// a NIB that needs a running NSApplication, which `swift test`
/// doesn't provide). Companion to `ForceDeleteAlert` for the
/// symmetric failure paths.
enum PRResolutionOfferAlert {
    /// Returns `nil` for non-terminal states (`.open`) so the factory
    /// owns the "PR isn't done, no offer" rule rather than asking
    /// every caller to pre-guard `state.resolutionWord`.
    static func configuration(prNumber: Int, prTitle: String, state: PRInfo.State) -> SheetAlert.Configuration? {
        guard let resolutionWord = state.resolutionWord else { return nil }
        let titlePrefix = prTitle.isEmpty ? "" : "\(prTitle)\n\n"
        return SheetAlert.Configuration(
            messageText: "Pull request #\(prNumber) \(resolutionWord)",
            informativeText: "\(titlePrefix)Delete the worktree now? This will delete the worktree but not the branch.",
            style: .informational,
            primaryButton: "Delete Worktree",
            secondaryButton: "Keep"
        )
    }
}
