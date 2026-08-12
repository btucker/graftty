import Darwin
import Foundation
import os
import Testing
@testable import GrafttyKit

/// Correctness tests should not race the production session-start deadline
/// while the full Swift Testing suite is saturating the cooperative executor.
/// `InstructionStoreDeadlineTests` exercises the bounded-load behavior
/// separately with an intentionally short deadline.
private func loadInstructions(
    from fixture: InstructionFilesystemFixture,
    preferredPaths: [String] = []
) async -> InstructionSet? {
    await InstructionStore.load(
        repoPath: fixture.repo.path,
        worktreePath: fixture.worktree.path,
        applicationSupportDirectory: fixture.applicationSupport,
        preferredPaths: preferredPaths,
        budget: .seconds(10)
    )
}

@Suite("""
@spec INSTR-1.1: When instruction files are loaded for a worktree, the application shall discover them from `~/Library/Application Support/Graftty/.graftty`, the current worktree's `.graftty`, and the main checkout's `.graftty`, and shall resolve each relative path from the first readable regular file in that precedence order.
""")
struct InstructionStoreTests {

    @Test func resolvesEachRelativePathIndependentlyByRootPrecedence() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }

        try fixture.write("APP ROOT", root: fixture.applicationSupport, relativePath: "GRAFTTY.md")
        try fixture.write("WORKTREE ROOT", root: fixture.worktree, relativePath: "GRAFTTY.md")
        try fixture.write("MAIN ROOT", root: fixture.repo, relativePath: "GRAFTTY.md")
        try fixture.write(
            "WORKTREE SCOPE",
            root: fixture.worktree,
            relativePath: "feature-login/GRAFTTY.md"
        )
        try fixture.write(
            "MAIN SCOPE",
            root: fixture.repo,
            relativePath: "feature-login/GRAFTTY.md"
        )
        try fixture.write(
            "MAIN GROUP",
            root: fixture.repo,
            relativePath: "research/GRAFTTY.md"
        )
        try fixture.write(
            "APP UNMATCHED",
            root: fixture.applicationSupport,
            relativePath: "ops/GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["GRAFTTY.md"]?.shared == "APP ROOT")
        #expect(set?.documents["feature-login/GRAFTTY.md"]?.shared == "WORKTREE SCOPE")
        #expect(set?.documents["research/GRAFTTY.md"]?.shared == "MAIN GROUP")
        #expect(set?.documents["ops/GRAFTTY.md"]?.shared == "APP UNMATCHED")
    }

    @Test func absentDirectoriesProduceNoSet() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }

        let set = await loadInstructions(from: fixture)

        #expect(set == nil)
    }

    @Test func unrecognizedFilenamesAreSkipped() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write("ignored", root: fixture.worktree, relativePath: "README.md")
        try fixture.write("ignored", root: fixture.worktree, relativePath: "GRAFTTY..md")
        try fixture.write("kept", root: fixture.worktree, relativePath: "ok/GRAFTTY.md")

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents.keys.sorted() == ["ok/GRAFTTY.md"])
    }

    @Test func legacyFilenameLoadsUnderItsCanonicalPath() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write(
            "LEGACY ROLE",
            root: fixture.worktree,
            relativePath: "research/GRAFTTY.vector-db.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["research/vector-db/GRAFTTY.md"]?.shared == "LEGACY ROLE")
        #expect(set?.documents["research/GRAFTTY.vector-db.md"] == nil)
    }

    @Test func canonicalFilenameWinsOverLegacyAliasWithinOneRoot() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write(
            "LEGACY ROLE",
            root: fixture.worktree,
            relativePath: "GRAFTTY.feature-login.md"
        )
        try fixture.write(
            "CANONICAL ROLE",
            root: fixture.worktree,
            relativePath: "feature-login/GRAFTTY.md"
        )
        // An uppercase key sorts before the legacy filename and exercises the
        // opposite discovery order. Precedence must not depend on directory
        // enumeration order.
        try fixture.write(
            "CANONICAL UPPERCASE ROLE",
            root: fixture.worktree,
            relativePath: "AAA/GRAFTTY.md"
        )
        try fixture.write(
            "LEGACY UPPERCASE ROLE",
            root: fixture.worktree,
            relativePath: "GRAFTTY.AAA.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["feature-login/GRAFTTY.md"]?.shared == "CANONICAL ROLE")
        #expect(set?.documents["AAA/GRAFTTY.md"]?.shared == "CANONICAL UPPERCASE ROLE")
        let diagnostics = try #require(set?.diagnostics)
        #expect(diagnostics.count == 2)
        #expect(diagnostics.allSatisfy { $0.kind == .legacyFileShadowed })
        #expect(diagnostics.contains {
            $0.preferredPath.hasSuffix("/.graftty/feature-login/GRAFTTY.md")
                && $0.shadowedPath.hasSuffix("/.graftty/GRAFTTY.feature-login.md")
        })
        #expect(diagnostics.contains {
            $0.preferredPath.hasSuffix("/.graftty/AAA/GRAFTTY.md")
                && $0.shadowedPath.hasSuffix("/.graftty/GRAFTTY.AAA.md")
        })
    }

    @Test func rootPrecedenceAppliesAcrossCanonicalAndLegacyNames() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write(
            "APP LEGACY OVERRIDE",
            root: fixture.applicationSupport,
            relativePath: "GRAFTTY.feature-login.md"
        )
        try fixture.write(
            "WORKTREE CANONICAL",
            root: fixture.worktree,
            relativePath: "feature-login/GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["feature-login/GRAFTTY.md"]?.shared == "APP LEGACY OVERRIDE")
    }

    @Test("A non-file override is a miss, so a lower-precedence regular file can load")
    func fifoOverrideDoesNotBlockOrSuppressMainFile() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let fifo = fixture.applicationSupport
            .appendingPathComponent(InstructionStore.directoryName, isDirectory: true)
            .appendingPathComponent("GRAFTTY.md")
        try FileManager.default.createDirectory(
            at: fifo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        #expect(mkfifo(fifo.path, 0o600) == 0)
        try fixture.write("MAIN FALLBACK", root: fixture.repo, relativePath: "GRAFTTY.md")

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["GRAFTTY.md"]?.shared == "MAIN FALLBACK")
    }

    @Test("A symlink never causes instruction loading to read outside an instruction root")
    func symlinkOverrideDoesNotExposeItsTarget() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let secret = fixture.root.appendingPathComponent("secret")
        try "DO NOT LOAD".write(to: secret, atomically: true, encoding: .utf8)
        let link = fixture.applicationSupport
            .appendingPathComponent(InstructionStore.directoryName, isDirectory: true)
            .appendingPathComponent("GRAFTTY.md")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        try fixture.write("MAIN FALLBACK", root: fixture.repo, relativePath: "GRAFTTY.md")

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["GRAFTTY.md"]?.shared == "MAIN FALLBACK")
    }

    @Test("A symlinked ancestor never causes instruction loading to leave its root")
    func symlinkedDirectoryOverrideDoesNotExposeItsTarget() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        try "DO NOT LOAD".write(
            to: outside.appendingPathComponent("GRAFTTY.md"),
            atomically: true,
            encoding: .utf8
        )
        let instructionDirectory = fixture.applicationSupport
            .appendingPathComponent(InstructionStore.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: instructionDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: instructionDirectory.appendingPathComponent("research"),
            withDestinationURL: outside
        )
        try fixture.write(
            "MAIN FALLBACK",
            root: fixture.repo,
            relativePath: "research/GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["research/GRAFTTY.md"]?.shared == "MAIN FALLBACK")
    }

    @Test("Overlay paths with different case remain distinct")
    func caseAliasesDoNotCrossOverlayRoots() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write(
            "APP MIXED CASE",
            root: fixture.applicationSupport,
            relativePath: "Research/vector-db/GRAFTTY.md"
        )
        try fixture.write(
            "MAIN EXACT CASE",
            root: fixture.repo,
            relativePath: "research/vector-db/GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(
            set?.documents["Research/vector-db/GRAFTTY.md"]?.shared
                == "APP MIXED CASE"
        )
        #expect(
            set?.documents["research/vector-db/GRAFTTY.md"]?.shared
                == "MAIN EXACT CASE"
        )
    }

    @Test("An iCloud dataless placeholder is rejected before any content read")
    func datalessRegularFileIsNotReadable() {
        var st = stat()
        st.st_mode = S_IFREG | 0o600
        st.st_flags = UInt32(SF_DATALESS)
        #expect(!InstructionStore.isMaterializedRegularFile(st))
    }
}

@Suite("""
@spec INSTR-1.2: When an instruction file is created or edited in the current worktree filesystem, the application shall use those current bytes at the next session start without requiring the file to be staged or committed.
""")
struct InstructionWorkingTreeReadTests {

    @Test func currentWorktreeEditsTakeEffectImmediately() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        let file = try fixture.write(
            "FIRST",
            root: fixture.worktree,
            relativePath: "feature-login/GRAFTTY.md"
        )
        try "UNCOMMITTED EDIT".write(to: file, atomically: true, encoding: .utf8)

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["feature-login/GRAFTTY.md"]?.shared == "UNCOMMITTED EDIT")
    }
}

@Suite("""
@spec INSTR-7.1: The application shall bound one instruction load to at most 64 files, truncate any single file to 32768 bytes and the whole set to 131072 bytes, and mark every truncated file with a visible truncation marker.
""")
struct InstructionStoreLimitTests {

    @Test func perFileCapTruncatesWithAMarker() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write(
            String(repeating: "x", count: InstructionStore.perFileByteCap + 500),
            root: fixture.worktree,
            relativePath: "GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.hasSuffix(InstructionStore.truncationMarker))
        #expect(shared.utf8.count <= InstructionStore.perFileByteCap)
    }

    @Test func fileCountIsBoundedAndPreferredFilesComeFirst() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        for index in 0..<(InstructionStore.maxFiles + 10) {
            try fixture.write(
                "body",
                root: fixture.worktree,
                relativePath: "groups/\(index)/GRAFTTY.md"
            )
        }
        try fixture.write(
            "viewer role",
            root: fixture.worktree,
            relativePath: "viewer/GRAFTTY.md"
        )

        let set = await loadInstructions(
            from: fixture,
            preferredPaths: ["viewer/GRAFTTY.md"]
        )

        #expect(set?.documents.count == InstructionStore.maxFiles)
        #expect(set?.documents["viewer/GRAFTTY.md"]?.shared == "viewer role")
    }

    @Test func totalByteCapBoundsTheWholeSet() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        for index in 0..<5 {
            try fixture.write(
                String(repeating: "x", count: InstructionStore.perFileByteCap + 500),
                root: fixture.worktree,
                relativePath: "w\(index)/GRAFTTY.md"
            )
        }

        let set = await loadInstructions(from: fixture)
        let total = set?.documents.values.reduce(0) {
            $0 + $1.shared.utf8.count + $1.privateText.utf8.count
        } ?? 0

        #expect(total <= InstructionStore.totalByteCap)
        #expect(set?.documents.count == InstructionStore.totalByteCap / InstructionStore.perFileByteCap)
    }

    @Test func truncationNeverSplitsMultiByteScalars() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        try fixture.write(
            String(repeating: "\u{2014}", count: InstructionStore.perFileByteCap),
            root: fixture.worktree,
            relativePath: "GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)
        let shared = set?.documents["GRAFTTY.md"]?.shared ?? ""

        #expect(shared.utf8.count <= InstructionStore.perFileByteCap)
        #expect(!shared.unicodeScalars.contains(Unicode.Scalar(0xFFFD)!))
    }

    @Test func raggedTotalBudgetNeverEmitsAnUnmarkedFragment() async throws {
        let fixture = try InstructionFilesystemFixture()
        defer { fixture.remove() }
        for name in ["a", "b", "c"] {
            try fixture.write(
                String(repeating: "x", count: InstructionStore.perFileByteCap + 1),
                root: fixture.worktree,
                relativePath: "\(name)/GRAFTTY.md"
            )
        }
        try fixture.write(
            String(repeating: "x", count: InstructionStore.perFileByteCap - 8),
            root: fixture.worktree,
            relativePath: "d/GRAFTTY.md"
        )
        try fixture.write(
            String(repeating: "x", count: 20),
            root: fixture.worktree,
            relativePath: "e/GRAFTTY.md"
        )

        let set = await loadInstructions(from: fixture)

        #expect(set?.documents["e/GRAFTTY.md"] == nil)
    }
}

@Suite("""
@spec INSTR-7.2: When an instruction load exceeds the one-second response budget, the application shall produce no instruction set without awaiting late filesystem work.
""")
struct InstructionStoreDeadlineTests {

    @Test func deadlineReturnsBeforeSynchronousWorkFinishes() async {
        let releaseOperation = DispatchSemaphore(value: 0)
        let operationFinished = InstructionOperationState()
        defer { releaseOperation.signal() }

        let set = await InstructionStore.loadWithinBudget(
            .milliseconds(20)
        ) {
            releaseOperation.wait()
            operationFinished.markFinished()
            return InstructionSet(documents: [
                "GRAFTTY.md": InstructionDocument.parse("too late"),
            ])
        }

        #expect(set == nil)
        #expect(!operationFinished.isFinished)
    }
}

private final class InstructionOperationState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: false)

    var isFinished: Bool { lock.withLock { $0 } }

    func markFinished() {
        lock.withLock { $0 = true }
    }
}
