import Foundation

/// A classified file discovered under `.graftty/`.
///
/// @spec INSTR-3.1
/// There are exactly two forms. `<dir>/GRAFTTY.md` applies to every key
/// beneath `<dir>`; `<dir>/GRAFTTY.<leaf>.md` applies to the single key
/// `<dir>/<leaf>`. Any other name is skipped.
public enum InstructionFile: Equatable, Sendable {
    /// `<dir>/GRAFTTY.md`. `directory` is "" at the root of `.graftty/`.
    case group(directory: String)
    /// `<dir>/GRAFTTY.<leaf>.md`, addressing the worktree key `<dir>/<leaf>`.
    case leaf(key: String)

    private static let prefix = "GRAFTTY."
    private static let suffix = ".md"
    private static let groupFilename = "GRAFTTY.md"

    /// Classifies a path relative to `.graftty/`. Returns nil for any name
    /// that is not one of the two supported forms.
    public static func classify(relativePath: String) -> InstructionFile? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else { return nil }
        let directory = components.dropLast().joined(separator: "/")

        if filename == groupFilename {
            return .group(directory: directory)
        }

        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else {
            return nil
        }
        let leaf = String(
            filename.dropFirst(prefix.count).dropLast(suffix.count)
        )
        guard !leaf.isEmpty else { return nil }
        return .leaf(key: directory.isEmpty ? leaf : directory + "/" + leaf)
    }
}
