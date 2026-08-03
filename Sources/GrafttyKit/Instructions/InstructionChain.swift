import Foundation

/// Builds the ordered list of `.graftty/`-relative paths that apply to a
/// worktree key.
///
/// @spec INSTR-5.1
/// The stack is every ancestor directory's group file from the root inward,
/// then the worktree's own leaf file at its parent level. Depth is the
/// ordering — there is no specificity ranking to compute.
public enum InstructionChain {

    public static func paths(forKey key: String) -> [String] {
        var result = ["GRAFTTY.md"]
        let components = key.split(separator: "/").map(String.init)
        guard let leaf = components.last else { return result }

        // Ancestor group files, root-most first. Excludes the key's own
        // directory-form, which covers descendants only.
        for depth in 1..<components.count {
            let directory = components.prefix(depth).joined(separator: "/")
            result.append(directory + "/GRAFTTY.md")
        }

        let parent = components.dropLast().joined(separator: "/")
        let leafFile = "GRAFTTY." + leaf + ".md"
        result.append(parent.isEmpty ? leafFile : parent + "/" + leafFile)
        return result
    }
}
