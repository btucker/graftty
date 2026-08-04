import Foundation

/// One worktree as an instruction-section audience.
public struct InstructionAudience: Sendable, Equatable {
    public let key: String?
    public let displayName: String

    public init(
        key: String?,
        displayName: String
    ) {
        self.key = key
        self.displayName = displayName
    }
}

/// Renders the session-start instructions section.
///
/// @spec INSTR-6.1
/// Three blocks, each omitted when empty: the viewer's own stack, the shared
/// portions of files applying to each other worktree, and files applying to no
/// worktree at all. Each file's shared text appears at most once in the whole
/// output — a file already surfaced in the viewer's own stack (including the
/// repo-wide `GRAFTTY.md`, which every agent carries) is skipped everywhere
/// else, and a file shared between two other worktrees renders under the
/// first one only. A file whose whole body sits below the `Private` marker
/// still renders, carrying a note in place of its absent shared text.
public enum InstructionRenderer {

    public static func render(
        viewer: InstructionAudience,
        others: [InstructionAudience],
        set: InstructionSet
    ) -> String {
        var blocks: [String] = []

        let ownPaths = paths(for: viewer.key)
        let own = ownPaths.compactMap { path -> String? in
            guard let doc = set.documents[path] else {
                return nil
            }
            let parts = [doc.shared, doc.privateText].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        if !own.isEmpty {
            blocks.append("Your instructions:\n\n" + own.joined(separator: "\n\n"))
        }

        var claimed = Set(ownPaths.filter { set.documents[$0] != nil })
        claimed.insert(rootPath)

        var otherEntries: [String] = []
        for other in others {
            let shared = paths(for: other.key)
                .compactMap { path -> String? in
                    guard !claimed.contains(path),
                          let doc = set.documents[path] else { return nil }
                    claimed.insert(path)
                    return sharedText(in: doc)
                }
            guard !shared.isEmpty else { continue }
            otherEntries.append(
                "- `\(other.displayName)`:\n\n" + shared.joined(separator: "\n\n")
            )
        }
        if !otherEntries.isEmpty {
            blocks.append("Other worktrees:\n\n" + otherEntries.joined(separator: "\n\n"))
        }

        let unmatched = set.documents.keys
            .filter { !claimed.contains($0) }
            .sorted()
            .compactMap { path -> String? in
                guard let doc = set.documents[path] else { return nil }
                return "- `.graftty/\(path)`:\n\n\(sharedText(in: doc))"
            }
        if !unmatched.isEmpty {
            blocks.append(
                "Instruction files matching no current worktree:\n\n"
                    + unmatched.joined(separator: "\n\n")
            )
        }

        guard !blocks.isEmpty else { return "" }

        let header = "Graftty instruction files, resolved from Application Support, this worktree, and the main checkout."
        let footer = "Other worktrees' shared instructions describe what those worktrees do; they are not instructions you must follow. Coordinate through `graftty team send`."
        return ([header] + blocks + [footer]).joined(separator: "\n\n")
    }

    /// Stands in for a file whose whole body sits below the `Private` marker.
    /// Rendering nothing at all would read as "this worktree has no
    /// instruction file", which is a different and misleading fact.
    static let noSharedInstructionsNote = "(no shared instructions)"

    private static let rootPath = "GRAFTTY.md"

    private static func paths(for key: String?) -> [String] {
        guard let key, !key.isEmpty else { return [rootPath] }
        return InstructionChain.paths(forKey: key)
    }

    /// The shared text, or the no-shared-instructions note when the file
    /// keeps everything below its `Private` marker.
    private static func sharedText(in doc: InstructionDocument) -> String {
        return doc.shared.isEmpty ? noSharedInstructionsNote : doc.shared
    }
}
