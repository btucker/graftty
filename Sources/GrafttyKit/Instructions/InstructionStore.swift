import Foundation
import os

/// Every instruction file discovered for one repository, parsed.
public struct InstructionSet: Sendable, Equatable {
    /// Parsed documents keyed by `.graftty/`-relative path.
    public let documents: [String: InstructionDocument]
    /// Active leaf documents keyed by the worktree whose committed `HEAD`
    /// supplied them.
    public let leafDocumentsByWorktreePath: [String: InstructionDocument]
    /// Worktrees whose leaf was resolved from their own `HEAD`, including
    /// worktrees where that committed leaf does not exist. The latter matters:
    /// an absent branch leaf must not fall back to a same-named main leaf.
    public let resolvedLeafWorktreePaths: Set<String>

    public init(
        documents: [String: InstructionDocument],
        leafDocumentsByWorktreePath: [String: InstructionDocument] = [:],
        resolvedLeafWorktreePaths: Set<String> = []
    ) {
        self.documents = documents
        self.leafDocumentsByWorktreePath = leafDocumentsByWorktreePath
        self.resolvedLeafWorktreePaths = resolvedLeafWorktreePaths.union(
            leafDocumentsByWorktreePath.keys
        )
    }
}

/// One active worktree leaf to read from that worktree's committed `HEAD`.
public struct InstructionLeafSource: Sendable, Equatable {
    public let worktreePath: String
    public let relativePath: String

    public init(worktreePath: String, relativePath: String) {
        self.worktreePath = worktreePath
        self.relativePath = relativePath
    }
}

/// Reads `.graftty/` from committed Git trees.
///
/// @spec INSTR-1.1
/// When instruction files are loaded, the application shall read group and
/// unmatched leaf files from the committed HEAD of the main checkout and each
/// active worktree's leaf file from that worktree's committed HEAD, rather
/// than from any working tree, and shall produce no instruction set when no
/// committed instruction content can be read.
public enum InstructionStore {

    private enum ReadTarget {
        case main(relativePath: String)
        case leaf(InstructionLeafSource)

        var relativePath: String {
            switch self {
            case let .main(relativePath): relativePath
            case let .leaf(source): source.relativePath
            }
        }

        var isLeafSource: Bool {
            if case .leaf = self { return true }
            return false
        }

        func checkoutPath(mainRepoPath: String) -> String {
            switch self {
            case .main: mainRepoPath
            case let .leaf(source): source.worktreePath
            }
        }
    }

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
        leafSources: [InstructionLeafSource] = [],
        budget: Duration = gitBudget,
        using executor: CLIExecutor? = nil
    ) async -> InstructionSet? {
        let deadline = GitCommandDeadline(timeout: budget)
        let prefix = directoryName + "/"

        // `-z` because `ls-tree` otherwise C-quotes any path containing a
        // non-ASCII byte, a quote, a backslash, or a control character —
        // which would leave those files unmatched by the prefix filter below.
        let listing: String
        do {
            listing = try await GitRunner.run(
                args: ["ls-tree", "-r", "-z", "--name-only", "HEAD", prefix],
                at: repoPath,
                timeout: try deadline.remaining(),
                using: executor
            )
        } catch let error as CLIError {
            if case .timedOut = error {
                logger.error("git budget lapsed during main listing; omitting instructions")
                return nil
            }
            // A linked worktree may have a valid committed leaf even when the
            // main checkout has no resolvable HEAD (for example, an unborn
            // branch). Continue with an empty main listing and probe leaves.
            logger.error(
                "listing main .graftty at HEAD failed; continuing with worktree leaves"
            )
            listing = ""
        } catch {
            logger.error(
                "listing main .graftty at HEAD failed; continuing with worktree leaves"
            )
            listing = ""
        }

        let candidates = listing
            .split(separator: "\0")
            .map(String.init)
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }

        var seenWorktrees: Set<String> = []
        let validLeafSources = leafSources.filter { source in
            guard seenWorktrees.insert(source.worktreePath).inserted,
                  case .leaf = InstructionFile.classify(
                      relativePath: source.relativePath
                  ) else { return false }
            return true
        }
        let activeLeafPaths = Set(validLeafSources.map(\.relativePath))
        let applicableMainPaths = Set(validLeafSources.flatMap { source in
            guard case let .leaf(key) = InstructionFile.classify(
                relativePath: source.relativePath
            ) else { return [String]() }
            return InstructionChain.paths(forKey: key)
        })

        var seenMainPaths: Set<String> = []
        var applicableMainGroups: [String] = []
        var unmatchedMainGroups: [String] = []
        var mainLeaves: [String] = []
        var skipped: [String] = []
        for candidate in candidates {
            guard let kind = InstructionFile.classify(relativePath: candidate) else {
                skipped.append(candidate)
                continue
            }
            guard seenMainPaths.insert(candidate).inserted else { continue }
            // An active worktree owns this leaf even when the file is absent
            // on its branch. Never let the main checkout's copy act as an
            // implicit fallback.
            guard !activeLeafPaths.contains(candidate) else { continue }
            switch kind {
            case .group:
                let appliesToActiveWorktree = candidate == "GRAFTTY.md"
                    || applicableMainPaths.contains(candidate)
                if appliesToActiveWorktree {
                    applicableMainGroups.append(candidate)
                } else {
                    unmatchedMainGroups.append(candidate)
                }
            case .leaf:
                mainLeaves.append(candidate)
            }
        }
        if !skipped.isEmpty {
            logger.info(
                """
                skipped \(skipped.count, privacy: .public) .graftty entries not named \
                GRAFTTY.md or GRAFTTY.<leaf>.md: \(skipped.joined(separator: ", "))
                """
            )
        }
        // Prioritize groups that apply to a live worktree, then each live
        // worktree's own role. Unmatched main-checkout files remain available
        // for org-chart discoverability without being able to starve active
        // roles at either the file-count or byte cap. The existing cap covers
        // the combined plan, so adding worktrees cannot make prompts unbounded.
        let targets = Array(
            (
                applicableMainGroups.map(ReadTarget.main)
                    + validLeafSources.map(ReadTarget.leaf)
                    + unmatchedMainGroups.map(ReadTarget.main)
                    + mainLeaves.map(ReadTarget.main)
            ).prefix(maxFiles)
        )
        guard !targets.isEmpty else { return nil }

        // One `git show` per file. `git cat-file --batch` would read them all
        // in a single count-independent subprocess, but `CLIExecutor` has no
        // stdin channel to feed it object names; the shared deadline below is
        // what keeps the aggregate cost bounded in the meantime.
        var documents: [String: InstructionDocument] = [:]
        var leafDocuments: [String: InstructionDocument] = [:]
        var byteBudget = totalByteCap
        var failed: [String] = []
        for target in targets {
            guard byteBudget > 0 else { break }
            guard let remaining = try? deadline.remaining() else {
                logger.error("git budget lapsed mid-read; omitting instructions")
                return nil
            }
            let body: String
            do {
                body = try await GitRunner.run(
                    args: ["show", "HEAD:\(prefix)\(target.relativePath)"],
                    at: target.checkoutPath(mainRepoPath: repoPath),
                    timeout: remaining,
                    using: executor
                )
            } catch let error as CLIError {
                if case .timedOut = error {
                    logger.error("git budget lapsed mid-read; omitting instructions")
                    return nil
                }
                // Most worktrees will not opt into a leaf. `git show` reports
                // an absent path as a normal non-zero exit, so omission is the
                // expected result rather than a session-start error.
                if case .nonZeroExit = error, target.isLeafSource {
                    continue
                }
                failed.append(target.relativePath)
                continue
            } catch {
                failed.append(target.relativePath)
                continue
            }
            let capped = cap(body, to: min(perFileByteCap, byteBudget))
            byteBudget -= capped.utf8.count
            let document = InstructionDocument.parse(capped)
            switch target {
            case let .main(relativePath):
                documents[relativePath] = document
            case let .leaf(source):
                leafDocuments[source.worktreePath] = document
            }
        }
        if !failed.isEmpty {
            logger.error(
                """
                failed to read \(failed.count, privacy: .public) .graftty entries: \
                \(failed.joined(separator: ", "))
                """
            )
        }
        guard !documents.isEmpty || !leafDocuments.isEmpty else { return nil }
        return InstructionSet(
            documents: documents,
            leafDocumentsByWorktreePath: leafDocuments,
            resolvedLeafWorktreePaths: Set(validLeafSources.map(\.worktreePath))
        )
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
