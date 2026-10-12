import Foundation

/// Installs the existing provider plugin plan only when agent setup is
/// explicitly requested. Plain terminal hosting never depends on providers.
public actor HostAgentSetup {
    private let configuration: HostConfiguration
    private var configured: Set<TeamHookRuntime> = []
    private var tail: Task<Void, Error>?
    public init(configuration: HostConfiguration) { self.configuration = configuration }

    public func ensure(_ runtime: TeamHookRuntime) async throws {
        if configured.contains(runtime) { return }
        let previous = tail
        let configuration = configuration
        let task = Task {
            _ = try? await previous?.value
            try await Self.install(configuration: configuration, provider: runtime)
        }
        tail = task
        try await task.value
        configured.insert(runtime)
    }

    public static func install(configuration: HostConfiguration, provider: TeamHookRuntime? = nil, executor: (any CLIExecutor)? = nil) async throws {
        let cli = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("graftty").path
        let installer = AgentPluginInstaller(grafttyCLIPath: cli)
        let plan: AgentPluginSetupPlan
        do { plan = try installer.prepare(destinationRoot: configuration.stateDirectory.appendingPathComponent("agent-plugins")) }
        catch { throw HostRuntimeError.invalid("Graftty agent plugin resources are missing or unreadable: \(error). Reinstall the host package.") }
        let selected = AgentPluginSetupPlan(rootDirectory: plan.rootDirectory, installSteps: plan.installSteps.filter {
            provider == nil || $0.provider.rawValue == provider?.rawValue
        })
        let resolvedExecutor: any CLIExecutor
        if let executor {
            resolvedExecutor = executor
        } else {
            #if os(Linux)
            let home = NSHomeDirectory()
            let loginPath = try await HostAgentEnvironment.loginPath(shellPath: configuration.shell, home: home)
            let path = HostAgentEnvironment.path(
                inheritedPath: ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin",
                home: home, loginPath: loginPath)
            resolvedExecutor = HostAgentEnvironment.executor(path: path, base: CLIRunner())
            #else
            resolvedExecutor = CLIRunner()
            #endif
        }
        let report = await installer.install(selected, executor: resolvedExecutor)
        guard report.succeeded else {
            let failures = report.results.filter { !$0.succeeded }.map {
                "\($0.step.provider.displayName): \($0.errorDescription ?? "plugin install failed")"
            }.joined(separator: "; ")
            throw HostRuntimeError.invalid("Install and authenticate the requested provider CLI, then run graftty-host setup --install-agent-plugins. \(failures)")
        }
    }
}
