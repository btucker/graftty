import Foundation
import GrafttyProtocol

/// Shared server-side validation for every worktree-creation surface. UI
/// clients sanitize while typing, but the local socket and HTTP endpoint are
/// trust boundaries too: a raw client must not be able to turn
/// `<repo>/.worktrees/<name>` into a path outside `.worktrees` with `..` or an
/// absolute component.
public enum WorktreeCreationInput {
    public static func validationError(
        worktreeName: String,
        branchName: String,
        existing: Bool = false
    ) -> String? {
        if let error = identifierError(worktreeName, label: "worktree name", path: true) {
            return error
        }
        // Existing refs come from Git discovery and may contain characters
        // outside the deliberately narrow worktree-name alphabet. Preserve
        // them byte-for-byte and let `git worktree add` validate the ref.
        if existing {
            return branchName.isEmpty ? "branch name must not be empty" : nil
        }
        return identifierError(branchName, label: "branch name", path: false)
    }

    private static func identifierError(_ value: String, label: String, path: Bool) -> String? {
        guard !value.isEmpty else { return "\(label) must not be empty" }
        if path && (value as NSString).isAbsolutePath {
            return "worktree name must be relative"
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return "\(label) contains an invalid path component"
        }
        guard WorktreeNameSanitizer.trimForSubmit(value) == value else {
            return "\(label) must not start or end with whitespace, '-' or '.'"
        }
        guard WorktreeNameSanitizer.sanitize(value) == value else {
            return "\(label) contains unsupported characters"
        }
        return nil
    }
}
