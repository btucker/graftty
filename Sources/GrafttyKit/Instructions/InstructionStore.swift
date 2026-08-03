import Foundation

/// Every instruction file discovered for one repository, parsed.
public struct InstructionSet: Sendable, Equatable {
    /// Parsed documents keyed by `.graftty/`-relative path.
    public let documents: [String: InstructionDocument]
    /// Classification of each discovered file, keyed by the same path.
    public let files: [String: InstructionFile]

    public init(
        documents: [String: InstructionDocument],
        files: [String: InstructionFile]
    ) {
        self.documents = documents
        self.files = files
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

    public static let perFileByteCap = 32_768
    public static let totalByteCap = 131_072
    public static let maxFiles = 64
    public static let gitTimeout: Duration = .seconds(5)
    public static let truncationMarker = "\n\n[graftty: instructions truncated]"

    public static let directoryName = ".graftty"

    public static func load(
        repoPath: String,
        using executor: CLIExecutor? = nil
    ) async -> InstructionSet? {
        guard let listing = try? await GitRunner.run(
            args: ["ls-tree", "-r", "--name-only", "HEAD", directoryName + "/"],
            at: repoPath,
            timeout: gitTimeout,
            using: executor
        ) else { return nil }

        let prefix = directoryName + "/"
        let candidates = listing
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }

        var files: [String: InstructionFile] = [:]
        var ordered: [String] = []
        for candidate in candidates {
            guard let classified = InstructionFile.classify(relativePath: candidate) else {
                continue
            }
            guard files[candidate] == nil else { continue }
            files[candidate] = classified
            ordered.append(candidate)
            if ordered.count == maxFiles { break }
        }
        guard !ordered.isEmpty else { return nil }

        var documents: [String: InstructionDocument] = [:]
        var budget = totalByteCap
        for relative in ordered {
            guard budget > 0 else { break }
            guard let body = try? await GitRunner.run(
                args: ["show", "HEAD:\(prefix)\(relative)"],
                at: repoPath,
                timeout: gitTimeout,
                using: executor
            ) else { continue }
            let capped = cap(body, to: min(perFileByteCap, budget))
            budget -= capped.utf8.count
            documents[relative] = InstructionDocument.parse(capped)
        }
        guard !documents.isEmpty else { return nil }
        return InstructionSet(documents: documents, files: files)
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
