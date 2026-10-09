import ArgumentParser
import Foundation
import GrafttyKit

@main
struct GrafttyHostCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "graftty-host",
        abstract: "Persistent Graftty terminal and worktree host.",
        subcommands: [Serve.self, TrustClient.self, Status.self, Project.self, Setup.self, Pair.self])
}

struct HostOptions: ParsableArguments {
    @Option(help: "Persistent state directory.") var stateDirectory: String?
    @Option(help: "Private Unix socket directory.") var runtimeDirectory: String?

    func resolved() throws -> HostConfiguration {
        let state = stateDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? HostConfiguration.defaultStateDirectory()
        var result = try HostConfiguration.load(stateDirectory: state) ?? HostConfiguration(stateDirectory: state)
        result.stateDirectory = state
        if let runtimeDirectory { result.runtimeDirectory = URL(fileURLWithPath: runtimeDirectory).standardizedFileURL }
        return result
    }
}

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Serve local CLI requests and authenticated direct SSH.")
    @OptionGroup var paths: HostOptions
    @Option var bindAddress: String = "127.0.0.1"
    @Option var httpPort: Int = 8800
    @Option var sshPort: Int = 8801
    @Option(help: "Path to zmx executable.") var zmx: String?
    @Option(help: "Shell for new panes.") var shell: String?
    @Flag(help: "Enable pairing HTTP routes. Trust still requires local confirmation.") var enablePairing = false

    mutating func run() async throws {
        var config = try paths.resolved()
        config.bindAddress = bindAddress; config.httpPort = httpPort; config.sshPort = sshPort
        if let zmx { config.zmxExecutable = URL(fileURLWithPath: zmx) }
        if let shell { config.shell = shell }
        let service = try await HostService(configuration: config, enablePairing: enablePairing)
        try await service.run()
    }
}

struct Setup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Prepare state, agent hooks, and a stable host identity.")
    @OptionGroup var paths: HostOptions
    @Flag var json = false
    @Flag(help: "Install provider plugins while the host is running, without changing host state.") var installAgentPlugins = false
    mutating func run() async throws {
        let config = try paths.resolved()
        if let identity = try await HostSetup.prepare(configuration: config, installAgentPlugins: installAgentPlugins) {
            try printJSON(identity)
        } else {
            try printJSON(["installed": true])
        }
    }
}

struct TrustClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "trust-client", abstract: "Enroll a Mac public key over a trusted local shell.")
    @OptionGroup var paths: HostOptions
    @Flag var stdin = false
    @Flag var json = false
    mutating func run() async throws {
        guard stdin else { throw ValidationError("trust-client requires --stdin") }
        let config = try paths.resolved()
        try config.prepareDirectories()
        var bytes = Data()
        while let chunk = try FileHandle.standardInput.read(upToCount: 4096), !chunk.isEmpty {
            bytes.append(chunk)
            guard bytes.count <= 65536 else { throw ValidationError("trust request exceeds 64 KiB") }
        }
        let request = try JSONDecoder().decode(LinuxHostTrustRequest.self, from: bytes)
        guard !request.deviceID.isEmpty, !request.displayName.isEmpty,
              let data = Data(base64Encoded: request.publicKey) else { throw ValidationError("invalid trust request") }
        try HostService.trust(request, publicKeyData: data, configuration: config)
        try printJSON(HostService.identity(configuration: config))
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show host state and listening configuration.")
    @OptionGroup var paths: HostOptions
    @Flag var json = false
    mutating func run() async throws {
        let config = try paths.resolved()
        if FileManager.default.fileExists(atPath: HostAdministrationServer.socketPath(configuration: config)) {
            switch try await HostAdministrationServer.request(.status, configuration: config) {
            case .status(let status): try printJSON(status)
            case .error(let error): throw ValidationError(error)
            default: throw ValidationError("unexpected host response")
            }
        } else {
            let state = try AppState.load(from: config.stateDirectory)
            try printJSON(HostStatus(running: false, configuration: config, repositoryCount: state.repos.count,
                paneCount: state.repos.flatMap(\.worktrees).reduce(0) { $0 + $1.splitTree.leafCount }))
        }
    }
}

struct Project: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage registered repositories.", subcommands: [Add.self])
    struct Add: AsyncParsableCommand {
        @OptionGroup var paths: HostOptions
        @Argument var path: String
        @Flag var json = false
        mutating func run() async throws {
            let config = try paths.resolved()
            if FileManager.default.fileExists(atPath: HostAdministrationServer.socketPath(configuration: config)) {
                switch try await HostAdministrationServer.request(.registerRepository(path: path), configuration: config) {
                case .repository(let repo): try printJSON(repo)
                case .error(let error): throw ValidationError(error)
                default: throw ValidationError("unexpected host response")
                }
            } else {
                let lease = try HostProcessLease(configuration: config)
                defer { withExtendedLifetime(lease) {} }
                let runtime = try await HeadlessHostRuntime(configuration: config)
                try printJSON(try await runtime.registerRepository(path))
            }
        }
    }
}

func printJSON<Value: Encodable>(_ value: Value) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

struct Pair: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Inspect or confirm HTTP pairing on a host started with --enable-pairing.", subcommands: [Pending.self, Confirm.self, Cancel.self])
    struct Pending: AsyncParsableCommand {
        @OptionGroup var paths: HostOptions
        mutating func run() async throws { try await pairCommand(.pairingStatus, paths: paths) }
    }
    struct Confirm: AsyncParsableCommand {
        @OptionGroup var paths: HostOptions
        @Argument(help: "Six-digit code shown by both client and host.") var code: String
        mutating func run() async throws { try await pairCommand(.confirmPairing(code: code), paths: paths) }
    }
    struct Cancel: AsyncParsableCommand {
        @OptionGroup var paths: HostOptions
        mutating func run() async throws { try await pairCommand(.cancelPairing, paths: paths) }
    }
}

func pairCommand(_ request: HostAdminRequest, paths: HostOptions) async throws {
    let response = try await HostAdministrationServer.request(request, configuration: paths.resolved())
    if case .error(let error) = response { throw ValidationError(error) }
    try printJSON(response)
}
