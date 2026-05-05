import Foundation

public struct AgentHookInstallResult: Sendable, Equatable {
    public let writtenFiles: [URL]

    public init(writtenFiles: [URL]) {
        self.writtenFiles = writtenFiles
    }
}

public struct AgentHookInstaller: Sendable {
    public static let version = "1"

    public let rootDirectory: URL
    public let grafttyCLIPath: String

    public init(rootDirectory: URL, grafttyCLIPath: String) {
        self.rootDirectory = rootDirectory
        self.grafttyCLIPath = grafttyCLIPath
    }

    public static func rootDirectory(defaultDirectory: URL = AppState.defaultDirectory) -> URL {
        defaultDirectory.appendingPathComponent("agent-hooks", isDirectory: true)
    }

    public static func binDirectory(rootDirectory: URL) -> URL {
        rootDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public var binDirectory: URL {
        Self.binDirectory(rootDirectory: rootDirectory)
    }

    public func install() throws -> AgentHookInstallResult {
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)

        var written: [URL] = []
        let claudeWrapper = binDirectory.appendingPathComponent("claude")
        let codexWrapper = binDirectory.appendingPathComponent("codex")

        try writeIfChanged(
            AgentHookInstaller.wrapperScript(
                runtime: .claude,
                wrapperDirectory: binDirectory.path,
                realCommandName: "claude",
                grafttyCLIPath: grafttyCLIPath
            ),
            to: claudeWrapper,
            executable: true,
            written: &written
        )
        try writeIfChanged(
            AgentHookInstaller.wrapperScript(
                runtime: .codex,
                wrapperDirectory: binDirectory.path,
                realCommandName: "codex",
                grafttyCLIPath: grafttyCLIPath
            ),
            to: codexWrapper,
            executable: true,
            written: &written
        )

        return AgentHookInstallResult(writtenFiles: written)
    }

    public static func wrapperScript(
        runtime: TeamHookRuntime,
        wrapperDirectory: String,
        realCommandName: String,
        grafttyCLIPath: String
    ) -> String {
        let resolveBlock = realBinaryResolutionShell(
            wrapperDirectory: wrapperDirectory,
            realCommandName: realCommandName
        )
        let trapBlock = """
        cleanup() { \(shellCommandToken(grafttyCLIPath)) team unregister --runtime \(runtime.rawValue) 2>/dev/null || true; }
        trap cleanup EXIT
        """

        let runtimeBlock: String
        switch runtime {
        case .claude:
            let inlineJSON = claudeInlineSettingsJSON(grafttyCLIPath: grafttyCLIPath)
            let escapedJSON = shellLiteral(inlineJSON)
            runtimeBlock = """
            if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
              ( exec "$real_binary" --settings \(escapedJSON) "$@" )
            else
              ( exec "$real_binary" "$@" )
            fi
            """
        case .codex:
            runtimeBlock = """
            if [ "${GRAFTTY_DISABLE_AGENT_HOOKS:-}" != "1" ]; then
              \(shellCommandToken(grafttyCLIPath)) internal sync-codex-home
              ( exec env CODEX_HOME="$HOME/.graftty/agent-hooks/codex-home" "$real_binary" "$@" )
            else
              ( exec "$real_binary" "$@" )
            fi
            """
        }

        return """
        #!/bin/sh
        # GRAFTTY_AGENT_HOOK_WRAPPER version=\(version)
        # Hooks run: \(grafttyCLIPath) team hook \(runtime.rawValue)
        \(resolveBlock)

        \(trapBlock)

        \(runtimeBlock)
        exit $?
        """
    }

    private static func claudeInlineSettingsJSON(grafttyCLIPath: String) -> String {
        let cmd = grafttyCLIPath
        let payload: [String: Any] = [
            "hooks": [
                "SessionStart": hookEntries(command: "\(cmd) team hook claude session-start"),
                "PostToolUse": hookEntries(command: "\(cmd) team hook claude post-tool-use"),
                "Stop": hookEntries(command: "\(cmd) team hook claude stop"),
            ],
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func realBinaryResolutionShell(wrapperDirectory: String, realCommandName: String) -> String {
        """
        real_binary=""
        old_ifs="$IFS"
        IFS=":"
        for dir in $PATH; do
          if [ "$dir" = \(shellLiteral(wrapperDirectory)) ]; then
            continue
          fi
          if [ -x "$dir/\(realCommandName)" ]; then
            real_binary="$dir/\(realCommandName)"
            break
          fi
        done
        IFS="$old_ifs"

        if [ -z "$real_binary" ]; then
          printf '%s\\n' "graftty: unable to find real \(realCommandName) outside \(wrapperDirectory)" >&2
          exit 127
        fi
        """
    }

    private static func hookEntries(command: String) -> [[String: Any]] {
        [
            [
                "hooks": [
                    [
                        "type": "command",
                        "command": command,
                    ],
                ],
            ],
        ]
    }

    private func writeIfChanged(
        _ string: String,
        to url: URL,
        executable: Bool,
        written: inout [URL]
    ) throws {
        try writeIfChanged(Data(string.utf8), to: url, executable: executable, written: &written)
    }

    private func writeIfChanged(
        _ data: Data,
        to url: URL,
        executable: Bool,
        written: inout [URL]
    ) throws {
        let existing = try? Data(contentsOf: url)
        guard existing != data else {
            if executable {
                try makeExecutable(url)
            }
            return
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        if executable {
            try makeExecutable(url)
        }
        written.append(url)
    }

    private func makeExecutable(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }

    private static func shellCommandToken(_ value: String) -> String {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil ||
              value.contains("'") ||
              value.contains("\"")
        else {
            return value
        }
        return shellLiteral(value)
    }

    private static func shellLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
