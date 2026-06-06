import Foundation

/// Publishes and fetches presence documents via git refs on the repo's
/// `origin` remote (`refs/graftty/presence/<slug>`). The JSON document rides
/// in the commit message of an empty-tree commit: no working-tree writes, no
/// stdin-dependent plumbing, and `git for-each-ref --format=%(contents)` reads
/// all documents in a single subprocess call.
public enum PresenceRefSync {
    private static let refPrefix = "refs/graftty/presence/"

    static func refName(slug: String) -> String { "\(refPrefix)\(slug)" }

    /// @spec SYNC-2.1 (behavioral spec on PresenceRefSyncTests)
    public static func publish(_ doc: PresenceDocument, slug: String, repoPath: String) async throws {
        let json = String(decoding: try doc.encoded(), as: UTF8.self)
        // The empty tree is a fixed, well-known object; -w ensures it exists
        // in this repo's object store.
        let tree = try await GitRunner.run(
            args: ["hash-object", "-w", "-t", "tree", "/dev/null"], at: repoPath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Synthetic committer identity: presence commits must not depend on
        // (or pollute) the user's git config.
        let commit = try await GitRunner.run(
            args: [
                "-c", "user.name=graftty-presence",
                "-c", "user.email=presence@graftty.invalid",
                "commit-tree", tree, "-m", json,
            ],
            at: repoPath
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        // Force: each publish replaces the previous commit (no parent chain).
        _ = try await GitRunner.run(
            args: ["push", "--quiet", "--force", "origin", "\(commit):\(refName(slug: slug))"],
            at: repoPath
        )
    }

    /// @spec SYNC-2.2 (behavioral spec on PresenceRefSyncTests)
    public static func fetchAll(repoPath: String) async throws -> [PresenceDocument] {
        _ = try await GitRunner.run(
            args: [
                "fetch", "--quiet", "--force", "--prune", "origin",
                "+\(refPrefix)*:\(refPrefix)*",
            ],
            at: repoPath
        )
        // Single subprocess: %(contents) embeds each commit message on the
        // same line as its refname, separated by a tab. Presence JSON is
        // always single-line (sortedKeys, non-pretty), so each record appears
        // as exactly one line: `refs/graftty/presence/<slug>\t{json}`.
        // Multi-line messages from foreign tools produce additional continuation
        // lines that do not start with the ref prefix — those are silently ignored.
        let output = try await GitRunner.run(
            args: ["for-each-ref", "--format=%(refname)%09%(contents)", refPrefix],
            at: repoPath
        )
        var docs: [PresenceDocument] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix(refPrefix), let tabIdx = line.firstIndex(of: "\t") else { continue }
            let jsonSubstring = line[line.index(after: tabIdx)...].trimmingCharacters(in: .whitespaces)
            // Skip undecodable refs (foreign tools, future versions) rather
            // than failing the whole fetch.
            if let doc = try? PresenceDocument.decode(Data(jsonSubstring.utf8)) {
                docs.append(doc)
            }
        }
        return docs
    }

    /// @spec SYNC-2.3 (behavioral spec on PresenceRefSyncTests)
    public static func delete(slug: String, repoPath: String) async throws {
        _ = try await GitRunner.run(
            args: ["push", "--quiet", "origin", ":\(refName(slug: slug))"],
            at: repoPath
        )
        // best-effort — the remote delete already succeeded; a stale local
        // mirror is pruned by the next fetch anyway.
        _ = try? await GitRunner.run(
            args: ["update-ref", "-d", refName(slug: slug)], at: repoPath
        )
    }
}
