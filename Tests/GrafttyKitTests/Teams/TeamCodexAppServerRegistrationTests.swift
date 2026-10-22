import Foundation
import Testing
@testable import GrafttyKit

@Suite("Codex app-server registration")
struct TeamCodexAppServerRegistrationTests {
    @Test("App-server register helper writes metadata for canonical worktree and pane session.")
    func codexAppServerRegisterWritesCanonicalWorktreeMetadata() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)

        let record = try TeamCodexAppServerCore.register(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/codex.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: registeredAt
        )

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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shimBinDir = dir.appendingPathComponent("bin", isDirectory: true)
        let packageRoot = dir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@openai", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        let scriptDir = packageRoot.appendingPathComponent("bin", isDirectory: true)
        let script = scriptDir.appendingPathComponent("codex.js")
        let native = dir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@openai", isDirectory: true)
            .appendingPathComponent(CodexDeliveryBinaryResolver.platformPackageDirectoryName, isDirectory: true)
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent(CodexDeliveryBinaryResolver.targetTriple, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex")
        let shim = shimBinDir.appendingPathComponent("codex")

        try FileManager.default.createDirectory(at: shimBinDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: native.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/usr/bin/env node\n".write(to: script, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: native, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: native.path)
        try FileManager.default.createSymbolicLink(
            atPath: shim.path,
            withDestinationPath: "../node_modules/@openai/codex/bin/codex.js"
        )

        let storage = CodexAppServerSessionStorage(rootDirectory: dir.appendingPathComponent("records"))
        let record = try TeamCodexAppServerCore.register(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/codex.sock",
            realBinaryPath: shim.path,
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(record.realBinaryPath == native.path)
    }

    @Test("App-server register stores the native Codex binary from the in-package vendor fallback layout.")
    func codexAppServerRegisterStoresNativeCodexBinaryForInPackageVendorLayout() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let shimBinDir = dir.appendingPathComponent("bin", isDirectory: true)
        let packageRoot = dir
            .appendingPathComponent("node_modules", isDirectory: true)
            .appendingPathComponent("@openai", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: true)
        let scriptDir = packageRoot.appendingPathComponent("bin", isDirectory: true)
        let script = scriptDir.appendingPathComponent("codex.js")
        let native = packageRoot
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent(CodexDeliveryBinaryResolver.targetTriple, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex")
        let shim = shimBinDir.appendingPathComponent("codex")

        try FileManager.default.createDirectory(at: shimBinDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: native.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/usr/bin/env node\n".write(to: script, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: native, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: native.path)
        try FileManager.default.createSymbolicLink(
            atPath: shim.path,
            withDestinationPath: "../node_modules/@openai/codex/bin/codex.js"
        )

        let storage = CodexAppServerSessionStorage(rootDirectory: dir.appendingPathComponent("records"))
        let record = try TeamCodexAppServerCore.register(
            storage: storage,
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/codex.sock",
            realBinaryPath: shim.path,
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(record.realBinaryPath == native.path)
    }

    @Test("App-server unregister deletes only the exact team/worktree/pane record.")
    func codexAppServerUnregisterDeletesExactRecord() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let registeredAt = Date(timeIntervalSince1970: 1_700_000_000)
        try storage.write(.init(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/a.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: registeredAt
        ))
        try storage.write(.init(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-bbbbbbbb",
            socketPath: "/tmp/b.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 43,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_790,
            registeredAt: registeredAt
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let current = CodexAppServerSessionRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/current.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 42,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_789,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
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
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-codex-app-server-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = CodexAppServerSessionStorage(rootDirectory: dir)
        let current = CodexAppServerSessionRecord(
            teamID: "/repo",
            worktree: "/repo/.worktrees/alice",
            paneSessionName: "graftty-aaaaaaaa",
            socketPath: "/tmp/current.sock",
            realBinaryPath: "/opt/bin/codex",
            appServerPID: 43,
            appServerProcessStartTimeMicroseconds: 1_700_000_123_456_790,
            registeredAt: Date(timeIntervalSince1970: 1_700_000_000)
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
