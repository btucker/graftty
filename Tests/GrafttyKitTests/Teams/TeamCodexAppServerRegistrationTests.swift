import Foundation
import Testing
@testable import GrafttyKit

@Suite("Codex app-server registration")
struct TeamCodexAppServerRegistrationTests {
    private static let worktree = "/repo/.worktrees/alice"
    private static let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)

    private static func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func record(
        pane: String,
        socketPath: String,
        appServerPID: Int32,
        startTime: Int64 = 1_700_000_123_456_789
    ) -> CodexAppServerSessionRecord {
        CodexAppServerSessionRecord(
            teamID: "/repo",
            worktree: worktree,
            paneSessionName: pane,
            socketPath: socketPath,
            realBinaryPath: "/opt/bin/codex",
            appServerPID: appServerPID,
            appServerProcessStartTimeMicroseconds: startTime,
            registeredAt: registeredAt
        )
    }

    private static func register(
        storage: CodexAppServerSessionStorage,
        realBinaryPath: String
    ) throws -> CodexAppServerSessionRecord {
        try TeamCodexAppServerCore.register(
            storage: storage,
            teamID: "/repo",
            worktree: worktree,
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/codex.sock",
            realBinaryPath: realBinaryPath,
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: registeredAt
        )
    }

    /// `<directory>/vendor/<triple>/bin/codex`, where a Codex platform
    /// package (or the launcher package itself) keeps the native binary.
    private static func vendoredBinary(in directory: URL) -> URL {
        directory
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent(CodexDeliveryBinaryResolver.targetTriple, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex")
    }

    /// Installs the `@openai/codex` Node launcher under `root/node_modules`,
    /// an executable native binary at the path `nativeAt` derives from the
    /// launcher package root, and an npm-style `bin/codex` symlink to the
    /// launcher. Returns the symlink and the native binary.
    private static func installNodeShim(
        root: URL,
        nativeAt: (_ packageRoot: URL) -> URL
    ) throws -> (shim: URL, native: URL) {
        let fileManager = FileManager.default
        let packageRoot = root
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@openai", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        let scriptDir = packageRoot.appendingPathComponent("bin", isDirectory: true)
        let native = nativeAt(packageRoot)
        let shim = root
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex")

        try fileManager.createDirectory(at: shim.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env node\n".write(
            to: scriptDir.appendingPathComponent("codex.js"),
            atomically: true,
            encoding: .utf8
        )
        try "#!/bin/sh\n".write(to: native, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: native.path)
        try fileManager.createSymbolicLink(
            atPath: shim.path,
            withDestinationPath: "../node_modules/@openai/codex/bin/codex.js"
        )
        return (shim, native)
    }

    @Test("App-server register helper writes metadata for canonical worktree and pane session.")
    func codexAppServerRegisterWritesCanonicalWorktreeMetadata() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)

        let record = try Self.register(storage: storage, realBinaryPath: "/opt/bin/codex")

        #expect(record.teamID == "/repo")
        #expect(record.worktree == "/repo/.worktrees/alice")
        #expect(record.paneSessionName == "graftty-aaaaaaaa")
        #expect(record.socketPath == "/tmp/codex.sock")
        #expect(record.realBinaryPath == "/opt/bin/codex")
        #expect(record.appServerPID == 42)
        #expect(record.appServerProcessStartTimeMicroseconds == 1_700_000_123_456_789)

        let loaded = try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        )
        #expect(loaded == record)
    }

    @Test("App-server register stores the native Codex binary when the wrapper resolved a Node shim.")
    func codexAppServerRegisterStoresNativeCodexBinaryForNodeShim() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (shim, native) = try Self.installNodeShim(root: dir) { packageRoot in
            Self.vendoredBinary(in: packageRoot
                .deletingLastPathComponent()
                .appendingPathComponent(CodexDeliveryBinaryResolver.platformPackageDirectoryName, isDirectory: true))
        }

        let storage = CodexAppServerSessionStorage(rootDirectory: dir.appendingPathComponent("records"))
        let record = try Self.register(storage: storage, realBinaryPath: shim.path)

        #expect(record.realBinaryPath == native.path)
    }

    @Test("App-server register stores the native Codex binary from the in-package vendor fallback layout.")
    func codexAppServerRegisterStoresNativeCodexBinaryForInPackageVendorLayout() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (shim, native) = try Self.installNodeShim(root: dir) { packageRoot in
            Self.vendoredBinary(in: packageRoot)
        }

        let storage = CodexAppServerSessionStorage(rootDirectory: dir.appendingPathComponent("records"))
        let record = try Self.register(storage: storage, realBinaryPath: shim.path)

        #expect(record.realBinaryPath == native.path)
    }

    @Test("App-server unregister deletes only the exact team/worktree/pane record.")
    func codexAppServerUnregisterDeletesExactRecord() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        try storage.write(Self.record(pane: "graftty-aaaaaaaa", socketPath: "/tmp/a.sock", appServerPID: 42))
        try storage.write(Self.record(
            pane: "graftty-bbbbbbbb",
            socketPath: "/tmp/b.sock",
            appServerPID: 43,
            startTime: 1_700_000_123_456_790
        ))

        let prior = try TeamCodexAppServerCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            expectedSocketPath: "/tmp/a.sock",
            expectedAppServerPID: 42
        )

        #expect(prior?.paneSessionName == "graftty-aaaaaaaa")
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        ) == nil)
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-bbbbbbbb"
        )?.socketPath == "/tmp/b.sock")
    }

    @Test("App-server unregister leaves current record when stale cleanup socket mismatches.")
    func codexAppServerUnregisterPreservesMismatchedSocketRecord() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let current = Self.record(pane: "graftty-aaaaaaaa", socketPath: "/tmp/current.sock", appServerPID: 42)
        try storage.write(current)

        let prior = try TeamCodexAppServerCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            expectedSocketPath: "/tmp/stale.sock",
            expectedAppServerPID: 42
        )

        #expect(prior == nil)
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        ) == current)
    }

    @Test("App-server unregister leaves current record when stale cleanup PID mismatches.")
    func codexAppServerUnregisterPreservesMismatchedPIDRecord() throws {
        let dir = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let current = Self.record(
            pane: "graftty-aaaaaaaa",
            socketPath: "/tmp/current.sock",
            appServerPID: 43,
            startTime: 1_700_000_123_456_790
        )
        try storage.write(current)

        let prior = try TeamCodexAppServerCore.unregister(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            expectedSocketPath: "/tmp/current.sock",
            expectedAppServerPID: 42
        )

        #expect(prior == nil)
        #expect(try storage.read(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa"
        ) == current)
    }
}
