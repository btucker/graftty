import Foundation

/// A classified file discovered under `.graftty/`.
///
/// @spec INSTR-3.1
/// The application shall recognize hierarchical files named GRAFTTY.md and
/// map each containing directory to the same worktree key and its descendants;
/// if a root contains a legacy GRAFTTY.<leaf>.md file, then the application
/// shall treat it as a fallback alias for the equivalent hierarchical path,
/// prefer the hierarchical file when both exist in that root while emitting a
/// diagnostic naming both files, and skip every other filename.
public enum InstructionFile: Equatable, Sendable {
    /// The worktree key matching the containing directory. The empty key is
    /// the repository-wide root scope.
    case scope(key: String)
    /// The pre-v0.5 exact-worktree form. Loading aliases this to the canonical
    /// hierarchical path and prefers `.scope` if both exist in one root.
    case legacyScope(key: String)

    private static let filename = "GRAFTTY.md"
    private static let legacyPrefix = "GRAFTTY."
    private static let suffix = ".md"

    var canonicalRelativePath: String {
        let key = switch self {
        case .scope(let key), .legacyScope(let key): key
        }
        return key.isEmpty ? Self.filename : key + "/" + Self.filename
    }

    var isLegacy: Bool {
        if case .legacyScope = self { return true }
        return false
    }

    /// Classifies a path relative to `.graftty/`.
    public static func classify(relativePath: String) -> InstructionFile? {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else { return nil }
        let directory = components.dropLast().joined(separator: "/")
        if filename == Self.filename {
            return .scope(key: directory)
        }
        guard filename.hasPrefix(legacyPrefix), filename.hasSuffix(suffix) else {
            return nil
        }
        let leaf = filename.dropFirst(legacyPrefix.count).dropLast(suffix.count)
        guard !leaf.isEmpty else { return nil }
        return .legacyScope(
            key: directory.isEmpty ? String(leaf) : directory + "/" + leaf
        )
    }
}
