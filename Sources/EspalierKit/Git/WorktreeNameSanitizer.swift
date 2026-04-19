import Foundation

/// Replaces characters that are unsafe in worktree directory names or git
/// branch refs with a single `-`. Used by the "Add Worktree" sheet to
/// filter user input as they type, so a user pasting `my feature/foo!`
/// ends up with the valid identifier `my-feature-foo-` rather than a
/// later `git worktree add` failure.
///
/// The allowed set is intentionally narrow and ASCII-only:
/// `A-Z a-z 0-9 . _ -`. This is a subset of what both macOS paths and
/// `git check-ref-format` accept, so a sanitized name is valid for both.
/// We do not trim leading/trailing dashes — doing so mid-type would
/// swallow the pending separator and corrupt the next keystroke; callers
/// trim on submit instead.
public enum WorktreeNameSanitizer {

    public static func sanitize(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var lastWasDash = false
        for scalar in input.unicodeScalars {
            let produceDash: Bool
            if isAllowed(scalar) {
                if scalar == "-" {
                    produceDash = true
                } else {
                    result.unicodeScalars.append(scalar)
                    lastWasDash = false
                    continue
                }
            } else {
                produceDash = true
            }
            if produceDash && !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result
    }

    private static func isAllowed(_ s: Unicode.Scalar) -> Bool {
        switch s {
        case "A"..."Z", "a"..."z", "0"..."9":
            return true
        case ".", "_", "-":
            return true
        default:
            return false
        }
    }
}
