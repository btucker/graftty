import Foundation

/// Runs explicit provider installation independently of host state setup.
/// Plain setup owns the host lease while persisting configuration and identity.
public enum HostSetup {
    public static func prepare(
        configuration: HostConfiguration,
        installAgentPlugins: Bool = false,
        executor: any CLIExecutor = CLIRunner()
    ) async throws -> LinuxHostIdentity? {
        if installAgentPlugins {
            try await HostAgentSetup.install(configuration: configuration, executor: executor)
            return nil
        }
        let lease = try HostProcessLease(configuration: configuration)
        defer { withExtendedLifetime(lease) {} }
        try configuration.save()
        _ = try AgentHookInstaller(rootDirectory: configuration.hooksDirectory, grafttyCLIPath: cliPath).install()
        return try identity(configuration: configuration)
    }

    public static var cliPath: String {
        URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("graftty").path
    }

    public static func identity(configuration: HostConfiguration) throws -> LinuxHostIdentity {
        let key = try HostIdentityStore(directory: configuration.identityDirectory).loadOrGenerateAndPersist()
        let id = try HostDeviceIDStore(directory: configuration.identityDirectory).loadOrGenerateAndPersist()
        return LinuxHostIdentity(deviceID: id.value, displayName: ProcessInfo.processInfo.hostName,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(), port: configuration.sshPort)
    }
}
