import Foundation

/// Publishes and fetches presence documents via git refs on the repo's
/// `origin` remote (`refs/graftty/presence/<slug>`). The JSON document rides
/// in the commit message of an empty-tree commit: no working-tree writes, no
/// stdin-dependent plumbing, and `git show -s --format=%B` reads it back.
public enum PresenceRefSync {
    static func refName(slug: String) -> String { "refs/graftty/presence/\(slug)" }

    /// @spec SYNC-2.1 (behavioral spec on PresenceRefSyncTests)
    public static func publish(_ doc: PresenceDocument, slug: String, repoPath: String) async throws {
        let json = String(decoding: try PresenceDocument.encode(doc), as: UTF8.self)
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
                "+refs/graftty/presence/*:refs/graftty/presence/*",
            ],
            at: repoPath
        )
        let refList = try await GitRunner.run(
            args: ["for-each-ref", "--format=%(refname)", "refs/graftty/presence/"],
            at: repoPath
        )
        var docs: [PresenceDocument] = []
        for ref in refList.split(separator: "\n").map(String.init) where !ref.isEmpty {
            guard let message = try? await GitRunner.run(
                args: ["show", "-s", "--format=%B", ref], at: repoPath
            ) else { continue }
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip undecodable refs (foreign tools, future versions) rather
            // than failing the whole fetch.
            if let doc = try? PresenceDocument.decode(Data(trimmed.utf8)) {
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
        // Drop the local mirror immediately as well.
        _ = try? await GitRunner.run(
            args: ["update-ref", "-d", refName(slug: slug)], at: repoPath
        )
    }
}
