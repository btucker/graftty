import Foundation

/// Paths and listening endpoints of a headless host. zmx sockets live in the
/// state directory so logout and runtime-directory cleanup do not end panes.
public struct HostConfiguration: Codable, Sendable, Equatable {
    public var bindAddress: String
    public var httpPort: Int
    public var sshPort: Int
    public var stateDirectory: URL
    public var runtimeDirectory: URL
    public var zmxExecutable: URL
    public var shell: String

    public init(
        bindAddress: String = "127.0.0.1",
        httpPort: Int = 8800,
        sshPort: Int = 8801,
        stateDirectory: URL = Self.defaultStateDirectory(),
        runtimeDirectory: URL = Self.defaultRuntimeDirectory(),
        zmxExecutable: URL = Self.defaultZmxExecutable(),
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
    ) {
        self.bindAddress = bindAddress
        self.httpPort = httpPort
        self.sshPort = sshPort
        self.stateDirectory = stateDirectory
        self.runtimeDirectory = runtimeDirectory
        self.zmxExecutable = zmxExecutable
        self.shell = shell
    }

    public var socketPath: String { runtimeDirectory.appendingPathComponent("graftty.sock").path }
    public var zmxDirectory: URL { stateDirectory.appendingPathComponent("zmx", isDirectory: true) }
    public var identityDirectory: URL { stateDirectory.appendingPathComponent("Remote", isDirectory: true) }
    public var hooksDirectory: URL { stateDirectory.appendingPathComponent("agent-hooks", isDirectory: true) }

    public static func defaultStateDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["GRAFTTY_STATE_DIR"], override.hasPrefix("/") { return URL(fileURLWithPath: override, isDirectory: true) }
        let base = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? $0 : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share").path
        return URL(fileURLWithPath: base).appendingPathComponent("graftty", isDirectory: true)
    }

    public static func defaultRuntimeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base = environment["XDG_RUNTIME_DIR"].flatMap { $0.hasPrefix("/") ? $0 : nil }
        return base.map { URL(fileURLWithPath: $0).appendingPathComponent("graftty", isDirectory: true) }
            ?? defaultStateDirectory(environment: environment)
    }

    public static func defaultZmxExecutable() -> URL {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent().appendingPathComponent("zmx")
        if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent("zmx")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return sibling
    }

    public func save() throws {
        try JSONEncoder().encode(self).write(to: stateDirectory.appendingPathComponent("host-config.json"), options: .atomic)
    }

    public static func load(stateDirectory: URL) throws -> HostConfiguration? {
        let path = stateDirectory.appendingPathComponent("host-config.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
    }

    public func prepareDirectories() throws {
        guard !bindAddress.isEmpty, (0...65535).contains(httpPort), (0...65535).contains(sshPort) else {
            throw HostRuntimeError.invalid("invalid bind address or port")
        }
        for directory in [stateDirectory, runtimeDirectory, zmxDirectory, identityDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: directory.path)
        }
    }
}

public enum HostRuntimeError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)
    case busy(String)
    public var description: String {
        switch self {
        case .invalid(let message), .notFound(let message), .busy(let message): return message
        }
    }
}
