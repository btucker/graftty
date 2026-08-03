import Foundation
import os

/// Every instruction file discovered for one repository, parsed.
public struct InstructionSet: Sendable, Equatable {
    /// Parsed documents keyed by `.graftty/`-relative path.
    public let documents: [String: InstructionDocument]

    public init(documents: [String: InstructionDocument]) {
        self.documents = documents
    }
}

/// Reads `.graftty/` from a repository's committed tree.
///
/// @spec INSTR-1.1
/// Content comes from the committed tree at `HEAD` in the main checkout, not
/// the working tree: that matches the propose-only authoring model, keeps a
/// multi-file edit from being observed half-applied, and avoids APFS
/// case-insensitivity diverging from git's case-sensitive tree. Every failure
/// degrades to `nil` so session start is never blocked.
public enum InstructionStore {

    private static let logger = Logger(
        subsystem: "com.btucker.graftty",
        category: "InstructionStore"
    )

    public static let perFileByteCap = 32_768
    public static let totalByteCap = 131_072
    public static let maxFiles = 64
    public static let truncationMarker = "\n\n[graftty: instructions truncated]"

    /// One absolute budget for *every* git subprocess of a single `load`,
    /// not a per-command timeout. Sized well under the CLI's 2s socket
    /// receive timeout: a session-start response that arrives late is not
    /// merely slow, it is lost — the CLI gives up while the inbox cursor has
    /// already advanced, discarding the team context and the queued peer
    /// messages along with the instructions.
    public static let gitBudget: Duration = .seconds(1)

    public static let directoryName = ".graftty"

    public static func load(
        repoPath: String,
        budget: Duration = gitBudget,
        using executor: CLIExecutor? = nil
    ) async -> InstructionSet? {
        let deadline = GitCommandDeadline(timeout: budget)
        let prefix = directoryName + "/"

        // `-z` because `ls-tree` otherwise C-quotes any path containing a
        // non-ASCII byte, a quote, a backslash, or a control character —
        // which would leave those files unmatched by the prefix filter below.
        guard let remaining = try? deadline.remaining(),
              let listing = try? await GitRunner.run(
                  args: ["ls-tree", "-r", "-z", "--name-only", "HEAD", prefix],
                  at: repoPath,
                  timeout: remaining,
                  using: executor
              )
        else {
            logger.info("listing .graftty at HEAD failed; omitting instructions")
            return nil
        }

        let candidates = listing
            .split(separator: "\0")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }

        var seen: Set<String> = []
        var ordered: [String] = []
        var skipped: [String] = []
        for candidate in candidates {
            guard InstructionFile.classify(relativePath: candidate) != nil else {
                skipped.append(candidate)
                continue
            }
            guard seen.insert(candidate).inserted else { continue }
            ordered.append(candidate)
            if ordered.count == maxFiles { break }
        }
        if !skipped.isEmpty {
            logger.info(
                """
                skipped \(skipped.count, privacy: .public) .graftty entries not named \
                GRAFTTY.md or GRAFTTY.<leaf>.md: \(skipped.joined(separator: ", "))
                """
            )
        }
        guard !ordered.isEmpty else { return nil }

        // One `git show` per file. `git cat-file --batch` would read them all
        // in a single count-independent subprocess, but `CLIExecutor` has no
        // stdin channel to feed it object names; the shared deadline below is
        // what keeps the aggregate cost bounded in the meantime.
        var documents: [String: InstructionDocument] = [:]
        var byteBudget = totalByteCap
        for relative in ordered {
            guard byteBudget > 0 else { break }
            guard let remaining = try? deadline.remaining() else {
                logger.info("git budget lapsed mid-read; omitting instructions")
                return nil
            }
            guard let body = try? await GitRunner.run(
                args: ["show", "HEAD:\(prefix)\(relative)"],
                at: repoPath,
                timeout: remaining,
                using: executor
            ) else { continue }
            let capped = cap(body, to: min(perFileByteCap, byteBudget))
            byteBudget -= capped.utf8.count
            documents[relative] = InstructionDocument.parse(capped)
        }
        guard !documents.isEmpty else { return nil }
        return InstructionSet(documents: documents)
    }

    /// Truncates `text` to at most `limit` UTF-8 bytes, including the
    /// appended `truncationMarker`. The slice always lands on a Unicode
    /// scalar boundary — never mid-sequence — so truncation cannot corrupt a
    /// multi-byte character into replacement characters (`U+FFFD`).
    static func cap(_ text: String, to limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        let markerBytes = truncationMarker.utf8.count
        guard limit > markerBytes else {
            // Not enough budget left to fit the marker itself; there is no
            // sensible truncation marker to append, so just clamp the body.
            return scalarPrefix(of: text, maxBytes: max(limit, 0))
        }
        let head = scalarPrefix(of: text, maxBytes: limit - markerBytes)
        return head + truncationMarker
    }

    /// The longest prefix of `text`, measured in whole Unicode scalars, whose
    /// UTF-8 encoding is no more than `maxBytes`.
    private static func scalarPrefix(of text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var byteCount = 0
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let scalarBytes = String(scalar).utf8.count
            guard byteCount + scalarBytes <= maxBytes else { break }
            byteCount += scalarBytes
            result.append(scalar)
        }
        return String(result)
    }
}
