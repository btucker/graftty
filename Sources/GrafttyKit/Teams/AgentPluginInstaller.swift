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
    case invalidPluginManifest
}

public struct AgentPluginInstaller: Sendable {
    /// Bump when the integration changes enough to re-offer first-time setup
    /// to users who declined it. Completed installations refresh per app build.
    public static let integrationRevision = 9

    private let resourceRoot: URL?
    private let grafttyCLIPath: String
    private let pluginVersion: String?

    /// Native plugin caches key by manifest version. Give every app build a
    /// distinct cache version, including builds with only hook-path changes.
    public static var appBuildPluginVersion: String? {
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            return nil
        }
        return pluginVersion(forBuild: build)
    }

    static func pluginVersion(forBuild build: String) -> String? {
        let parts = build.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { UInt($0) }
        guard numbers.count == parts.count else { return nil }
        return (numbers + Array(repeating: 0, count: 3 - numbers.count))
            .map(String.init).joined(separator: ".")
    }

    public init(
        resourceRoot: URL? = nil,
        grafttyCLIPath: String = "graftty",
        pluginVersion: String? = Self.appBuildPluginVersion
    ) {
        self.resourceRoot = resourceRoot
        self.grafttyCLIPath = grafttyCLIPath
        self.pluginVersion = pluginVersion
    }

    /// Materializes an app-owned marketplace snapshot. Provider configuration
    /// remains untouched until installation or an automatic refresh runs.
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
            // Source links can cross provider roots; cached plugins cannot.
            // Read through the original links before replacing staged copies.
            for path in [
                "plugins/graftty/skills/graftty/SKILL.md",
                "plugins/graftty/skills/graftty-team/SKILL.md",
                "plugins/graftty/.\(provider.rawValue)-plugin/plugin.json",
            ] {
                var contents = try Data(contentsOf: source.appendingPathComponent(path))
                if path.hasSuffix("plugin.json"), let pluginVersion {
                    guard var manifest = try JSONSerialization.jsonObject(with: contents) as? [String: Any] else {
                        throw AgentPluginInstallerError.invalidPluginManifest
                    }
                    manifest["version"] = pluginVersion
                    contents = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                }
                let stagedFile = staging.appendingPathComponent(path)
                try FileManager.default.removeItem(at: stagedFile)
                try contents.write(to: stagedFile)
            }
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
                    arguments: ["plugin", "add", "graftty@graftty"]
                ),
                AgentPluginInstallStep(
                    provider: .claude,
                    executable: "claude",
                    arguments: ["plugin", "marketplace", "add", claudeRoot]
                ),
                AgentPluginInstallStep(
                    provider: .claude,
                    executable: "claude",
                    arguments: ["plugin", "install", "graftty@graftty", "--scope", "user"]
                ),
                AgentPluginInstallStep(
                    provider: .claude,
                    executable: "claude",
                    arguments: ["plugin", "update", "graftty@graftty", "--scope", "user"]
                ),
            ]
        )
    }

    private func materializeHookCommands(in providerRoot: URL) throws {
        let hooksURL = providerRoot
            .appendingPathComponent("plugins/graftty/hooks/hooks.json")
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
    /// obtained installation consent, including refreshes of that installation.
    /// Each step is a direct executable invocation,
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

    /// Manual installation may replace an older Graftty Team plugin. Remove
    /// its hooks only after the new plugin is installed and enabled.
    public func installReplacingLegacy(
        _ plan: AgentPluginSetupPlan,
        executor: any CLIExecutor = CLIRunner(),
        timeout: Duration = .seconds(60)
    ) async -> AgentPluginInstallationReport {
        let installation = await install(plan, executor: executor, timeout: timeout)
        var results = installation.results
        for provider in AgentPluginProvider.allCases {
            guard installation.results.filter({ $0.step.provider == provider }).allSatisfy(\.succeeded) else {
                continue
            }
            let listStep = Self.listStep(for: provider)
            do {
                let output = try await executor.run(
                    command: listStep.executable,
                    args: listStep.arguments,
                    at: plan.rootDirectory.path,
                    timeout: timeout
                )
                let state = try Self.installedPlugins(
                    for: provider,
                    data: Data(output.stdout.utf8)
                )
                guard state.legacyEnabled else { continue }
                guard state.currentEnabled else {
                    results.append(AgentPluginInstallResult(
                        step: listStep,
                        output: output,
                        errorDescription: "new Graftty plugin is not enabled; kept the legacy plugin"
                    ))
                    continue
                }
                let removal = await install(
                    AgentPluginSetupPlan(
                        rootDirectory: plan.rootDirectory,
                        installSteps: [Self.legacyRemovalStep(for: provider)]
                    ),
                    executor: executor,
                    timeout: timeout
                )
                results.append(contentsOf: removal.results)
            } catch {
                results.append(AgentPluginInstallResult(
                    step: listStep,
                    output: nil,
                    errorDescription: Self.describe(error)
                ))
            }
        }
        return AgentPluginInstallationReport(results: results)
    }

    /// Refresh only enabled, currently installed user plugins. Replaying the
    /// initial installation unconditionally would undo provider-side removal
    /// or disabling. Inventory failures remain retryable installation errors.
    public func refresh(
        _ plan: AgentPluginSetupPlan,
        executor: any CLIExecutor = CLIRunner(),
        timeout: Duration = .seconds(60)
    ) async -> AgentPluginInstallationReport {
        var results: [AgentPluginInstallResult] = []
        for provider in AgentPluginProvider.allCases {
            let listStep = Self.listStep(for: provider)
            do {
                let output = try await executor.run(
                    command: listStep.executable,
                    args: listStep.arguments,
                    at: plan.rootDirectory.path,
                    timeout: timeout
                )
                let state = try Self.installedPlugins(for: provider, data: Data(output.stdout.utf8))
                guard !state.currentDisabled else { continue }
                guard state.currentEnabled || state.legacyEnabled else { continue }
                let steps = plan.installSteps.filter {
                    $0.provider == provider && (!state.currentEnabled || $0.arguments.prefix(2) != ["plugin", "install"])
                }
                let report = await install(
                    AgentPluginSetupPlan(rootDirectory: plan.rootDirectory, installSteps: steps),
                    executor: executor,
                    timeout: timeout
                )
                results.append(contentsOf: report.results)
                if report.succeeded && state.legacyEnabled {
                    let removal = await install(
                        AgentPluginSetupPlan(
                            rootDirectory: plan.rootDirectory,
                            installSteps: [Self.legacyRemovalStep(for: provider)]
                        ),
                        executor: executor,
                        timeout: timeout
                    )
                    results.append(contentsOf: removal.results)
                }
            } catch {
                results.append(AgentPluginInstallResult(
                    step: listStep, output: nil, errorDescription: Self.describe(error)
                ))
            }
        }
        return AgentPluginInstallationReport(results: results)
    }

    private struct InstalledPlugins {
        var currentEnabled: Bool
        var legacyEnabled: Bool
        var currentDisabled: Bool
    }

    private static func listStep(for provider: AgentPluginProvider) -> AgentPluginInstallStep {
        AgentPluginInstallStep(
            provider: provider,
            executable: provider.rawValue,
            arguments: provider == .codex
                ? ["plugin", "list", "--marketplace", "graftty", "--json"]
                : ["plugin", "list", "--json"]
        )
    }

    private static func legacyRemovalStep(for provider: AgentPluginProvider) -> AgentPluginInstallStep {
        AgentPluginInstallStep(
            provider: provider,
            executable: provider.rawValue,
            arguments: provider == .codex
                ? ["plugin", "remove", "graftty-team@graftty"]
                : ["plugin", "uninstall", "graftty-team@graftty", "--scope", "user"]
        )
    }

    private static func installedPlugins(for provider: AgentPluginProvider, data: Data) throws -> InstalledPlugins {
        switch provider {
        case .codex:
            let entries = try JSONDecoder().decode(CodexPluginInventory.self, from: data).installed
            return InstalledPlugins(
                currentEnabled: entries.contains { $0.pluginId == "graftty@graftty" && $0.installed && $0.enabled },
                legacyEnabled: entries.contains { $0.pluginId == "graftty-team@graftty" && $0.installed && $0.enabled },
                currentDisabled: entries.contains { $0.pluginId == "graftty@graftty" && $0.installed && !$0.enabled }
            )
        case .claude:
            let entries = try JSONDecoder().decode([ClaudePluginEntry].self, from: data)
            return InstalledPlugins(
                currentEnabled: entries.contains { $0.id == "graftty@graftty" && $0.scope == "user" && $0.enabled },
                legacyEnabled: entries.contains { $0.id == "graftty-team@graftty" && $0.scope == "user" && $0.enabled },
                currentDisabled: entries.contains { $0.id == "graftty@graftty" && $0.scope == "user" && !$0.enabled }
            )
        }
    }

    private struct CodexPluginInventory: Decodable {
        let installed: [Entry]
        struct Entry: Decodable {
            let pluginId: String
            let installed: Bool
            let enabled: Bool
        }
    }

    private struct ClaudePluginEntry: Decodable {
        let id: String
        let scope: String
        let enabled: Bool
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
