import Foundation

/// Builds the ordered list of `.graftty/`-relative paths that apply to a
/// worktree key.
///
/// @spec INSTR-5.1
/// The application shall resolve a worktree instruction stack as the GRAFTTY.md
/// file at the repository root and every directory component of the worktree
/// key, ordered from root to the exact worktree.
public enum InstructionChain {

    public static func paths(forKey key: String) -> [String] {
        var result = ["GRAFTTY.md"]
        let components = key.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return result }
        for depth in 1...components.count {
            let directory = components.prefix(depth).joined(separator: "/")
            result.append(directory + "/GRAFTTY.md")
        }
        return result
    }
}
