import Foundation

/// One worktree as an instruction-section audience.
public struct InstructionAudience: Sendable, Equatable {
    public let key: String?
    public let displayName: String
    /// Identifies the per-worktree leaf document loaded from this audience's
    /// committed `HEAD`. Nil retains the path-only behavior used by pure
    /// renderer clients and tests.
    public let worktreePath: String?

    public init(
        key: String?,
        displayName: String,
        worktreePath: String? = nil
    ) {
        self.key = key
        self.displayName = displayName
        self.worktreePath = worktreePath
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

    private enum Claim: Hashable {
        case mainPath(String)
        case worktreeLeaf(String)
    }

    public static func render(
        viewer: InstructionAudience,
        others: [InstructionAudience],
        set: InstructionSet
    ) -> String {
        var blocks: [String] = []

        let ownPaths = paths(for: viewer.key)
        let own = ownPaths.compactMap { path -> String? in
            guard let doc = document(at: path, for: viewer, in: set) else {
                return nil
            }
            let parts = [doc.shared, doc.privateText].filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
        }
        if !own.isEmpty {
            blocks.append("Your instructions:\n\n" + own.joined(separator: "\n\n"))
        }

        var claimed: Set<Claim> = []
        for path in ownPaths {
            if document(at: path, for: viewer, in: set) != nil
                || isResolvedLeaf(path, for: viewer, in: set) {
                claim(path, for: viewer, in: set, into: &claimed)
            }
        }
        claimed.insert(.mainPath(rootPath))

        var otherEntries: [String] = []
        for other in others {
            let shared = paths(for: other.key)
                .compactMap { path -> String? in
                    let key = claimKey(path, for: other, in: set)
                    guard !claimed.contains(key) else { return nil }
                    guard let doc = document(at: path, for: other, in: set) else {
                        if isResolvedLeaf(path, for: other, in: set) {
                            claim(path, for: other, in: set, into: &claimed)
                        }
                        return nil
                    }
                    claim(path, for: other, in: set, into: &claimed)
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
            .filter { !claimed.contains(.mainPath($0)) }
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

        let header = "Graftty instruction files, from committed `HEAD` trees."
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

    private static func document(
        at path: String,
        for audience: InstructionAudience,
        in set: InstructionSet
    ) -> InstructionDocument? {
        guard isResolvedLeaf(path, for: audience, in: set),
              let worktreePath = audience.worktreePath
        else { return set.documents[path] }
        return set.leafDocumentsByWorktreePath[worktreePath]
    }

    private static func isResolvedLeaf(
        _ path: String,
        for audience: InstructionAudience,
        in set: InstructionSet
    ) -> Bool {
        path == paths(for: audience.key).last
            && audience.worktreePath.map(
                set.resolvedLeafWorktreePaths.contains
            ) == true
    }

    private static func claimKey(
        _ path: String,
        for audience: InstructionAudience,
        in set: InstructionSet
    ) -> Claim {
        if isResolvedLeaf(path, for: audience, in: set),
           let worktreePath = audience.worktreePath {
            return .worktreeLeaf(worktreePath)
        }
        return .mainPath(path)
    }

    private static func claim(
        _ path: String,
        for audience: InstructionAudience,
        in set: InstructionSet,
        into claimed: inout Set<Claim>
    ) {
        let key = claimKey(path, for: audience, in: set)
        claimed.insert(key)
        if case .worktreeLeaf = key {
            // The worktree's resolved presence or absence owns this path;
            // suppress any same-named main copy from the unmatched block.
            claimed.insert(.mainPath(path))
        }
    }

    /// The shared text, or the no-shared-instructions note when the file
    /// keeps everything below its `Private` marker.
    private static func sharedText(in doc: InstructionDocument) -> String {
        return doc.shared.isEmpty ? noSharedInstructionsNote : doc.shared
    }
}
