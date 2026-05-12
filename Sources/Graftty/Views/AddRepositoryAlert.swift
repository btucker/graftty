import AppKit
import GrafttyKit

/// UI-shaping helper for the three-button choice presented when the
/// user picks a folder that isn't a git repo (`GIT-1.5`). Keeps the
/// string table and the non-git-repo factory out of `MainWindow.swift`
/// so they can be unit-tested. The `NSAlert` itself is constructed by
/// the caller from these values.
enum AddRepositoryAlert {
    static let buttons = [
        "Initialize Git Repository",
        "Add Without Git",
        "Cancel",
    ]
    static let defaultButtonIndex = 0

    enum Choice {
        case initializeGit
        case addWithoutGit
        case cancel
    }

    /// Maps the modal return code of an `NSAlert` constructed from
    /// `buttons` to a `Choice`. `.alertFirstButtonReturn` corresponds
    /// to the default (`buttons[0]`), and so on. Any other return is
    /// treated as Cancel so the user's Esc / window-close gestures
    /// don't add anything.
    static func choice(for response: NSApplication.ModalResponse) -> Choice {
        switch response {
        case .alertFirstButtonReturn: return .initializeGit
        case .alertSecondButtonReturn: return .addWithoutGit
        default: return .cancel
        }
    }

    /// Constructs the non-git `RepoEntry` registered when the user
    /// chooses "Add Without Git" (`GIT-1.7`). The single synthetic
    /// worktree's path equals the repo path; its branch label is the
    /// literal string `"main"`.
    static func makeNonGitRepoEntry(
        atPath path: String,
        displayName: String,
        bookmark: Data?
    ) -> RepoEntry {
        RepoEntry(
            path: path,
            displayName: displayName,
            worktrees: [WorktreeEntry(path: path, branch: "main")],
            bookmark: bookmark,
            isGitTracked: false
        )
    }
}
