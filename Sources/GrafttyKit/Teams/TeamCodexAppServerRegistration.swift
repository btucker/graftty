import Foundation

/// Maps a Node `codex.js` launcher to the platform-native Codex executable
/// that delivery should spawn; any other path is returned unchanged.
public enum CodexDeliveryBinaryResolver {
    public static var targetTriple: String {
        #if os(macOS)
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #elseif arch(x86_64)
        return "x86_64-apple-darwin"
        #else
        return ""
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "aarch64-unknown-linux-musl"
        #elseif arch(x86_64)
        return "x86_64-unknown-linux-musl"
        #else
        return ""
        #endif
        #else
        return ""
        #endif
    }

    public static var platformPackageName: String {
        #if os(macOS)
        #if arch(arm64)
        return "@openai/codex-darwin-arm64"
        #elseif arch(x86_64)
        return "@openai/codex-darwin-x64"
        #else
        return ""
        #endif
        #elseif os(Linux)
        #if arch(arm64)
        return "@openai/codex-linux-arm64"
        #elseif arch(x86_64)
        return "@openai/codex-linux-x64"
        #else
        return ""
        #endif
        #else
        return ""
        #endif
    }

    public static var platformPackageDirectoryName: String {
        platformPackageName.split(separator: "/").last.map(String.init) ?? ""
    }

    public static func resolve(_ realBinaryPath: String, fileManager: FileManager = .default) -> String {
        guard !targetTriple.isEmpty, !platformPackageDirectoryName.isEmpty else {
            return realBinaryPath
        }

        let binaryURL = URL(fileURLWithPath: realBinaryPath)
        let scriptURL = binaryURL.resolvingSymlinksInPath()
        guard scriptURL.lastPathComponent == "codex.js",
              let script = try? String(contentsOf: scriptURL, encoding: .utf8),
              script.hasPrefix("#!/usr/bin/env node")
        else {
            return realBinaryPath
        }

        let packageRoot = scriptURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let openAIOrgRoot = packageRoot.deletingLastPathComponent()
        let candidateURLs = [
            openAIOrgRoot
                .appendingPathComponent(platformPackageDirectoryName, isDirectory: true)
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent(targetTriple, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex"),
            packageRoot
                .appendingPathComponent("vendor", isDirectory: true)
                .appendingPathComponent(targetTriple, isDirectory: true)
                .appendingPathComponent("bin", isDirectory: true)
                .appendingPathComponent("codex"),
        ]

        guard let nativeURL = candidateURLs.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) else {
            return realBinaryPath
        }
        return nativeURL.path
    }
}

/// Writes and removes the per-pane Codex app-server session record behind
/// `graftty team codex-app-server register|unregister`.
public enum TeamCodexAppServerCore {
    @discardableResult
    public static func register(
        storage: CodexAppServerSessionStorage,
        teamID: String,
        worktree: String,
        paneSessionName: String,
        socketPath: String,
        realBinaryPath: String,
        appServerPID: Int32,
        appServerProcessStartTimeMicroseconds: Int64,
        ownerPID: Int32? = nil,
        ownerProcessStartTimeMicroseconds: Int64? = nil,
        registeredAt: Date
    ) throws -> CodexAppServerSessionRecord {
        let deliveryBinaryPath = CodexDeliveryBinaryResolver.resolve(realBinaryPath)
        let record = CodexAppServerSessionRecord(
            teamID: teamID,
            worktree: worktree,
            paneSessionName: paneSessionName,
            socketPath: socketPath,
            realBinaryPath: deliveryBinaryPath,
            appServerPID: appServerPID,
            appServerProcessStartTimeMicroseconds: appServerProcessStartTimeMicroseconds,
            ownerPID: ownerPID,
            ownerProcessStartTimeMicroseconds: ownerProcessStartTimeMicroseconds,
            registeredAt: registeredAt
        )
        try storage.write(record)
        return record
    }

    @discardableResult
    public static func unregister(
        storage: CodexAppServerSessionStorage,
        teamID: String,
        worktree: String,
        paneSessionName: String,
        expectedSocketPath: String? = nil,
        expectedAppServerPID: Int32? = nil
    ) throws -> CodexAppServerSessionRecord? {
        guard let prior = try storage.read(
            teamID: teamID,
            worktree: worktree,
            paneSessionName: paneSessionName
        ) else { return nil }
        if let expectedSocketPath, prior.socketPath != expectedSocketPath {
            return nil
        }
        if let expectedAppServerPID, prior.appServerPID != expectedAppServerPID {
            return nil
        }
        return try storage.deleteIfMatching(prior) ? prior : nil
    }
}
