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

    private static func shellToken(_ value: String) -> String {
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
            return "Installed all provider plugins. Restart Graftty, then start new Codex and Claude sessions."
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
    public static let integrationRevision = 2

    private let resourceRoot: URL?

    public init(resourceRoot: URL? = nil) {
        self.resourceRoot = resourceRoot
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
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
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
            ]
        )
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
