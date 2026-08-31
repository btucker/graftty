import Foundation

public enum AgentPluginProvider: String, CaseIterable, Sendable {
    case codex
    case claude

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}

public struct AgentPluginInstallStep: Equatable, Sendable {
    public let provider: AgentPluginProvider
    public let executable: String
    public let arguments: [String]

    public init(
        provider: AgentPluginProvider,
        executable: String,
        arguments: [String]
    ) {
        self.provider = provider
        self.executable = executable
        self.arguments = arguments
    }

    public var shellCommand: String {
        ([executable] + arguments)
            .map(Self.shellToken)
            .joined(separator: " ")
    }

    static func shellToken(_ value: String) -> String {
        let safe = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_@%+=:,./-")
        )
        if !value.isEmpty,
           value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

public struct AgentPluginSetupPlan: Equatable, Sendable {
    public let rootDirectory: URL
    public let installSteps: [AgentPluginInstallStep]

    public var commands: [String] {
        installSteps.map(\.shellCommand)
    }

    public var shellScript: String {
        commands.joined(separator: "\n")
    }
}

public struct AgentPluginInstallResult: Equatable, Sendable {
    public let step: AgentPluginInstallStep
    public let output: CLIOutput?
    public let errorDescription: String?

    public var succeeded: Bool { errorDescription == nil }
}

public struct AgentPluginInstallationReport: Equatable, Sendable {
    public let results: [AgentPluginInstallResult]

    public var succeeded: Bool {
        results.allSatisfy(\.succeeded)
    }

    public var summary: String {
        let successCount = results.count(where: \.succeeded)
        guard successCount != results.count else {
            return "Installed all provider plugins. Start new Codex and Claude sessions."
        }
        let failures = results.compactMap { result -> String? in
            guard let error = result.errorDescription else { return nil }
            return "\(result.step.provider.displayName): \(error)"
        }.joined(separator: " ")
        return "Installed \(successCount) of \(results.count) provider-plugin steps. \(failures)"
    }
}

public enum AgentPluginInstallerError: Error, Equatable {
    case bundledResourcesMissing
}

public struct AgentPluginInstaller: Sendable {
    /// Bump when the bundled provider integration changes in a way that
    /// warrants presenting the launch-time install offer again.
    public static let integrationRevision = 6

    private let resourceRoot: URL?
    private let grafttyCLIPath: String

    public init(
        resourceRoot: URL? = nil,
        grafttyCLIPath: String = "graftty"
    ) {
        self.resourceRoot = resourceRoot
        self.grafttyCLIPath = grafttyCLIPath
    }

    /// Materializes an app-owned marketplace snapshot. Provider configuration
    /// remains untouched until Settings explicitly offers the returned install
    /// plan and the user accepts it.
    public func prepare(
        destinationRoot: URL = AppState.defaultDirectory
            .appendingPathComponent("agent-plugins", isDirectory: true)
    ) throws -> AgentPluginSetupPlan {
        guard let sourceRoot = resourceRoot ?? Self.bundledResourceRoot() else {
            throw AgentPluginInstallerError.bundledResourcesMissing
        }
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        for provider in AgentPluginProvider.allCases {
            let source = sourceRoot.appendingPathComponent(provider.rawValue, isDirectory: true)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw AgentPluginInstallerError.bundledResourcesMissing
            }
            let destination = destinationRoot.appendingPathComponent(
                provider.rawValue,
                isDirectory: true
            )
            // The destination path is registered with the provider plugin
            // marketplaces, so it must never be observed missing or partially
            // written. Materialize into a staging sibling on the same volume,
            // then swap it into place atomically.
            let staging = destinationRoot.appendingPathComponent(
                ".staging-\(provider.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            try materializeHookCommands(in: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(
                    destination,
                    withItemAt: staging
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
        }

        let codexRoot = destinationRoot.appendingPathComponent("codex", isDirectory: true).path
        let claudeRoot = destinationRoot.appendingPathComponent("claude", isDirectory: true).path
        return AgentPluginSetupPlan(
            rootDirectory: destinationRoot,
            installSteps: [
                AgentPluginInstallStep(
                    provider: .codex,
                    executable: "codex",
                    arguments: ["plugin", "marketplace", "add", codexRoot]
                ),
                AgentPluginInstallStep(
                    provider: .codex,
                    executable: "codex",
                    arguments: ["plugin", "add", "graftty-team@graftty"]
                ),
                AgentPluginInstallStep(
                    provider: .claude,
                    executable: "claude",
                    arguments: ["plugin", "marketplace", "add", claudeRoot]
                ),
                AgentPluginInstallStep(
                    provider: .claude,
                    executable: "claude",
                    arguments: ["plugin", "install", "graftty-team@graftty", "--scope", "user"]
                ),
                AgentPluginInstallStep(
                    provider: .claude,
                    executable: "claude",
                    arguments: ["plugin", "update", "graftty-team@graftty", "--scope", "user"]
                ),
            ]
        )
    }

    private func materializeHookCommands(in providerRoot: URL) throws {
        let hooksURL = providerRoot
            .appendingPathComponent("plugins/graftty-team/hooks/hooks.json")
        let data = try Data(contentsOf: hooksURL)
        let document = try JSONSerialization.jsonObject(with: data)
        let commandPrefix = AgentPluginInstallStep.shellToken(grafttyCLIPath)

        func rewrite(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.mapValues(rewrite)
            }
            if let array = value as? [Any] {
                return array.map(rewrite)
            }
            if let string = value as? String {
                return string.replacingOccurrences(
                    of: "graftty team hook",
                    with: "\(commandPrefix) team hook"
                )
            }
            return value
        }

        let rewritten = try JSONSerialization.data(
            withJSONObject: rewrite(document),
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try rewritten.write(to: hooksURL, options: .atomic)
    }

    /// Runs the structured installation plan only after the caller has
    /// obtained explicit consent. Each step is a direct executable invocation,
    /// not a shell string, and failures do not prevent the other provider from
    /// being attempted.
    public func install(
        _ plan: AgentPluginSetupPlan,
        executor: any CLIExecutor = CLIRunner(),
        timeout: Duration = .seconds(60)
    ) async -> AgentPluginInstallationReport {
        var results: [AgentPluginInstallResult] = []
        for step in plan.installSteps {
            do {
                let output = try await executor.run(
                    command: step.executable,
                    args: step.arguments,
                    at: plan.rootDirectory.path,
                    timeout: timeout
                )
                results.append(AgentPluginInstallResult(
                    step: step,
                    output: output,
                    errorDescription: nil
                ))
            } catch {
                results.append(AgentPluginInstallResult(
                    step: step,
                    output: nil,
                    errorDescription: Self.describe(error)
                ))
            }
        }
        return AgentPluginInstallationReport(results: results)
    }

    private static func bundledResourceRoot() -> URL? {
        GrafttyKitResourceBundle.bundle.bundleURL
            .appendingPathComponent("AgentPlugins", isDirectory: true)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case CLIError.notFound(let command):
            return "\(command) was not found on Graftty's PATH. Copy the commands above and run them in your configured terminal."
        case CLIError.nonZeroExit(_, let exitCode, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "installation exited with status \(exitCode)."
                : "installation exited with status \(exitCode): \(detail)"
        case CLIError.launchFailed(_, let message):
            return "installation could not start: \(message)"
        case CLIError.timedOut(_, let seconds):
            return "installation timed out after \(seconds) seconds."
        default:
            return String(describing: error)
        }
    }
}
