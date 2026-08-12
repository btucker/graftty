import Darwin
import Foundation
import os

/// A non-fatal problem found while resolving instruction files.
public struct InstructionDiagnostic: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case legacyFileShadowed
    }

    public let kind: Kind
    public let preferredPath: String
    public let shadowedPath: String

    public init(kind: Kind, preferredPath: String, shadowedPath: String) {
        self.kind = kind
        self.preferredPath = preferredPath
        self.shadowedPath = shadowedPath
    }
}

/// Every instruction file discovered for one repository, parsed.
public struct InstructionSet: Sendable, Equatable {
    /// Parsed documents keyed by `.graftty/`-relative path.
    public let documents: [String: InstructionDocument]
    /// Non-fatal conflicts encountered while choosing those documents.
    public let diagnostics: [InstructionDiagnostic]

    public init(
        documents: [String: InstructionDocument],
        diagnostics: [InstructionDiagnostic] = []
    ) {
        self.documents = documents
        self.diagnostics = diagnostics
    }
}

/// Reads `.graftty/` directly from the filesystem.
///
/// @spec INSTR-1.1
/// When instruction files are loaded for a worktree, the application shall
/// discover them from `~/Library/Application Support/Graftty/.graftty`, the
/// current worktree's `.graftty`, and the main checkout's `.graftty`, and
/// shall resolve each relative path from the first readable regular file in
/// that precedence order.
public enum InstructionStore {

    private struct RootInventory: Sendable {
        let instructionDirectory: URL
        /// Canonical logical path → actual path inside this root. Legacy
        /// filenames alias to their canonical path without rewriting disk.
        let actualPathByCanonicalPath: [String: String]
    }

    private struct DiscoveredPath {
        let actualPath: String
        let isLegacy: Bool
    }

    private static let logger = Logger(
        subsystem: "com.btucker.graftty",
        category: "InstructionStore"
    )

    public static let perFileByteCap = 32_768
    public static let totalByteCap = 131_072
    public static let maxFiles = 64
    public static let truncationMarker = "\n\n[graftty: instructions truncated]"
    public static let directoryName = ".graftty"
    public static let loadBudget: Duration = .seconds(1)

    public static var defaultApplicationSupportDirectory: URL {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Graftty", isDirectory: true)
    }

    /// Loads instruction bytes away from the caller's executor and abandons
    /// the result after `budget`. Filesystem metadata and reads can still be
    /// unexpectedly slow on networked or File Provider volumes; session-start
    /// handling must neither pin the app's main actor nor await late I/O.
    public static func load(
        repoPath: String,
        worktreePath: String,
        applicationSupportDirectory: URL = defaultApplicationSupportDirectory,
        preferredPaths: [String] = [],
        budget: Duration = loadBudget
    ) async -> InstructionSet? {
        await loadWithinBudget(budget) {
            loadSynchronously(
                repoPath: repoPath,
                worktreePath: worktreePath,
                applicationSupportDirectory: applicationSupportDirectory,
                preferredPaths: preferredPaths
            )
        }
    }

    /// @spec INSTR-7.2
    /// When an instruction load exceeds the one-second response budget, the
    /// application shall produce no instruction set without awaiting late
    /// filesystem work.
    static func loadWithinBudget(
        _ budget: Duration,
        operation: @escaping @Sendable () -> InstructionSet?
    ) async -> InstructionSet? {
        let (stream, continuation) = AsyncStream<InstructionSet?>.makeStream()
        let loadTask = Task.detached(priority: .utility) {
            let result = operation()
            guard !Task.isCancelled else { return }
            continuation.yield(result)
        }
        let duration = budget.components
        let timeoutSeconds = max(
            0,
            Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        )
        // A sleeping Swift task can itself be starved when filesystem work
        // occupies the cooperative executor. Dispatch owns the deadline so
        // the timeout remains independent of the blocked load task.
        let timeoutWorkItem = DispatchWorkItem {
            continuation.yield(nil)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeoutSeconds,
            execute: timeoutWorkItem
        )
        defer {
            loadTask.cancel()
            timeoutWorkItem.cancel()
            continuation.finish()
        }
        for await result in stream {
            return result
        }
        return nil
    }

    private static func loadSynchronously(
        repoPath: String,
        worktreePath: String,
        applicationSupportDirectory: URL,
        preferredPaths: [String]
    ) -> InstructionSet? {
        guard !Task.isCancelled else { return nil }
        let roots = uniqueRoots([
            applicationSupportDirectory,
            URL(fileURLWithPath: worktreePath, isDirectory: true),
            URL(fileURLWithPath: repoPath, isDirectory: true),
        ])

        var inventories: [RootInventory] = []
        var discovered: Set<String> = []
        var diagnostics: [InstructionDiagnostic] = []
        var skippedCount = 0
        for root in roots {
            guard !Task.isCancelled else { return nil }
            let instructionDirectory = root.appendingPathComponent(
                directoryName,
                isDirectory: true
            )
            var rootPaths: [String: DiscoveredPath] = [:]
            var rootDiagnostics: [InstructionDiagnostic] = []
            discoverFiles(
                beneath: instructionDirectory,
                instructionDirectory: instructionDirectory,
                relativeDirectory: "",
                discovered: &rootPaths,
                diagnostics: &rootDiagnostics,
                skippedCount: &skippedCount
            )
            discovered.formUnion(rootPaths.keys)
            diagnostics.append(contentsOf: rootDiagnostics)
            inventories.append(
                RootInventory(
                    instructionDirectory: instructionDirectory,
                    actualPathByCanonicalPath: rootPaths.mapValues(\.actualPath)
                )
            )
        }
        if skippedCount > 0 {
            logger.info(
                """
                skipped \(skippedCount, privacy: .public) unrecognized .graftty files
                """
            )
        }
        for diagnostic in diagnostics {
            logger.warning(
                """
                ignored legacy instruction file \(diagnostic.shadowedPath, privacy: .public) because canonical file \(diagnostic.preferredPath, privacy: .public) exists
                """
            )
        }
        guard !discovered.isEmpty else { return nil }

        var ordered: [String] = []
        var seen: Set<String> = []
        for path in preferredPaths where discovered.contains(path) {
            guard InstructionFile.classify(relativePath: path) != nil,
                  seen.insert(path).inserted else { continue }
            ordered.append(path)
        }
        for path in discovered.sorted() where seen.insert(path).inserted {
            ordered.append(path)
        }
        ordered = Array(ordered.prefix(maxFiles))

        var documents: [String: InstructionDocument] = [:]
        var byteBudget = totalByteCap
        for relativePath in ordered {
            guard !Task.isCancelled else { return nil }
            guard byteBudget > 0 else { break }
            let limit = min(perFileByteCap, byteBudget)
            guard let body = firstReadableBody(
                relativePath: relativePath,
                inventories: inventories,
                limit: limit
            ) else { continue }
            guard let capped = cap(body, to: limit) else { continue }
            byteBudget -= capped.utf8.count
            documents[relativePath] = InstructionDocument.parse(capped)
        }

        guard !documents.isEmpty else { return nil }
        return InstructionSet(documents: documents, diagnostics: diagnostics)
    }

    private static func uniqueRoots(_ candidates: [URL]) -> [URL] {
        var paths: Set<String> = []
        return candidates.compactMap { candidate in
            let root = candidate.standardizedFileURL
            return paths.insert(root.path).inserted ? root : nil
        }
    }

    /// Recursively discovers only materialized directories and regular files.
    /// `lstat` is intentional: following a symlink here could escape an
    /// instruction root or enter an unbounded directory cycle.
    private static func discoverFiles(
        beneath directory: URL,
        instructionDirectory: URL,
        relativeDirectory: String,
        discovered: inout [String: DiscoveredPath],
        diagnostics: inout [InstructionDiagnostic],
        skippedCount: inout Int
    ) {
        guard !Task.isCancelled,
              isMaterializedDirectory(atPath: directory.path),
              let names = try? FileManager.default.contentsOfDirectory(
                  atPath: directory.path
              ) else { return }

        for name in names.sorted() {
            guard !Task.isCancelled else { return }
            let relativePath = relativeDirectory.isEmpty
                ? name
                : relativeDirectory + "/" + name
            let entry = directory.appendingPathComponent(name)
            var st = stat()
            guard lstat(entry.path, &st) == 0 else { continue }
            if isMaterializedDirectory(st) {
                discoverFiles(
                    beneath: entry,
                    instructionDirectory: instructionDirectory,
                    relativeDirectory: relativePath,
                    discovered: &discovered,
                    diagnostics: &diagnostics,
                    skippedCount: &skippedCount
                )
            } else if isMaterializedRegularFile(st) {
                if let instruction = InstructionFile.classify(relativePath: relativePath) {
                    let canonicalPath = instruction.canonicalRelativePath
                    if let existing = discovered[canonicalPath] {
                        if existing.isLegacy && !instruction.isLegacy {
                            diagnostics.append(
                                shadowingDiagnostic(
                                    preferredPath: relativePath,
                                    shadowedPath: existing.actualPath,
                                    instructionDirectory: instructionDirectory
                                )
                            )
                            discovered[canonicalPath] = DiscoveredPath(
                                actualPath: relativePath,
                                isLegacy: false
                            )
                        } else if !existing.isLegacy && instruction.isLegacy {
                            diagnostics.append(
                                shadowingDiagnostic(
                                    preferredPath: existing.actualPath,
                                    shadowedPath: relativePath,
                                    instructionDirectory: instructionDirectory
                                )
                            )
                        }
                    } else {
                        discovered[canonicalPath] = DiscoveredPath(
                            actualPath: relativePath,
                            isLegacy: instruction.isLegacy
                        )
                    }
                } else {
                    skippedCount += 1
                }
            }
        }
    }

    private static func shadowingDiagnostic(
        preferredPath: String,
        shadowedPath: String,
        instructionDirectory: URL
    ) -> InstructionDiagnostic {
        InstructionDiagnostic(
            kind: .legacyFileShadowed,
            preferredPath: instructionDirectory.appendingPathComponent(preferredPath).path,
            shadowedPath: instructionDirectory.appendingPathComponent(shadowedPath).path
        )
    }

    private static func firstReadableBody(
        relativePath: String,
        inventories: [RootInventory],
        limit: Int
    ) -> String? {
        for inventory in inventories {
            guard !Task.isCancelled else { return nil }
            guard let actualPath = inventory.actualPathByCanonicalPath[relativePath] else {
                continue
            }
            if let body = readMaterializedRegularFile(
                relativePath: actualPath,
                beneath: inventory.instructionDirectory,
                limit: limit
            ) {
                return body
            }
        }
        return nil
    }

    /// Opens the instruction root separately so system symlinks above that
    /// trusted root (notably `/var` -> `/private/var`) remain valid, then uses
    /// `O_NOFOLLOW_ANY` for the relative path so no symlink beneath the root
    /// can expose arbitrary local files.
    private static func readMaterializedRegularFile(
        relativePath: String,
        beneath instructionDirectory: URL,
        limit: Int
    ) -> String? {
        let directoryDescriptor = open(
            instructionDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard directoryDescriptor >= 0 else { return nil }
        defer { close(directoryDescriptor) }

        var directoryStat = stat()
        guard fstat(directoryDescriptor, &directoryStat) == 0,
              isMaterializedDirectory(directoryStat) else { return nil }

        var beforeOpen = stat()
        guard fstatat(
            directoryDescriptor,
            relativePath,
            &beforeOpen,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
              isMaterializedRegularFile(beforeOpen) else { return nil }

        let descriptor = openat(
            directoryDescriptor,
            relativePath,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var afterOpen = stat()
        guard fstat(descriptor, &afterOpen) == 0,
              isMaterializedRegularFile(afterOpen) else { return nil }

        // The extra bytes keep decoding away from the truncation boundary;
        // the longest valid UTF-8 scalar is four bytes.
        let readLimit = max(limit, 0) + 8
        var data = Data()
        data.reserveCapacity(readLimit)
        var buffer = [UInt8](repeating: 0, count: min(8_192, readLimit))
        while data.count < readLimit {
            guard !Task.isCancelled else { return nil }
            let requested = min(buffer.count, readLimit - data.count)
            let count = read(descriptor, &buffer, requested)
            if count > 0 {
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isMaterializedDirectory(atPath path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && isMaterializedDirectory(st)
    }

    private static func isMaterializedDirectory(_ st: stat) -> Bool {
        MaterializedFilesystemEntry.isDirectory(st)
    }

    static func isMaterializedRegularFile(_ st: stat) -> Bool {
        MaterializedFilesystemEntry.isRegularFile(st)
    }

    /// Truncates `text` to at most `limit` UTF-8 bytes, including the
    /// appended `truncationMarker`. Returns nil when the marker itself cannot
    /// fit, so a total-budget remainder never emits an unmarked fragment. The
    /// slice always lands on a Unicode scalar boundary — never mid-sequence —
    /// so truncation cannot corrupt a multi-byte character into replacement
    /// characters (`U+FFFD`).
    static func cap(_ text: String, to limit: Int) -> String? {
        guard text.utf8.count > limit else { return text }
        let markerBytes = truncationMarker.utf8.count
        guard limit >= markerBytes else { return nil }
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
