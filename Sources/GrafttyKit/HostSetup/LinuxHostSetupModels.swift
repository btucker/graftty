import Foundation

public struct LinuxHostDestination: Sendable, Equatable {
    public let value: String
    public init(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("-"), !value.contains("://"),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              !value.contains("/"), !value.contains("\\") else {
            throw LinuxHostSetupError.invalidPlan("Enter an SSH config alias, hostname, or user@hostname, without SSH options.")
        }
        self.value = value
    }
}

public struct LinuxHostResolvedSSH: Sendable, Equatable {
    public let hostname: String
    public let user: String
    public let port: Int

    public static func parse(_ configuration: String) throws -> Self {
        var values: [String: String] = [:]
        for line in configuration.split(separator: "\n") {
            let pair = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            if pair.count == 2 { values[String(pair[0])] = String(pair[1]) }
        }
        guard let hostname = values["hostname"], !hostname.isEmpty,
              let user = values["user"], !user.isEmpty,
              let port = values["port"].flatMap(Int.init), (1...65535).contains(port) else {
            throw LinuxHostSetupError.invalidPlan("System SSH could not resolve this destination's hostname, user, and port.")
        }
        return Self(hostname: hostname, user: user, port: port)
    }
}

public struct LinuxHostPlatform: Sendable, Equatable {
    public let architecture: String
    public let homeDirectory: String

    public static func parse(_ output: String) throws -> Self {
        let lines = output.split(separator: "\n").map(String.init)
        guard lines.count == 3, lines[0] == "ubuntu", ["x86_64", "aarch64"].contains(lines[1]), lines[2].hasPrefix("/") else {
            throw LinuxHostSetupError.invalidPlan("Linux auto-setup requires Ubuntu on x86_64 or ARM64. Check the destination and its operating system.")
        }
        return Self(architecture: lines[1], homeDirectory: lines[2])
    }
}

public struct LinuxHostProject: Sendable, Equatable, Hashable {
    public var localPath: String
    public var branch: String
    public var directoryName: String

    public init(localPath: String, branch: String, directoryName: String) {
        self.localPath = localPath
        self.branch = branch
        self.directoryName = directoryName
    }
}

public enum LinuxHostArchive: Sendable, Equatable {
    case release(version: String)
    /// A trusted developer-built archive with the same layout as a release.
    case local(URL)
}

public struct LinuxHostSetupPlan: Sendable, Equatable {
    public let destination: LinuxHostDestination
    public let destinationRoot: String
    public let projects: [LinuxHostProject]
    public let archive: LinuxHostArchive
    public let client: LinuxHostTrustRequest

    public init(destination: LinuxHostDestination, destinationRoot: String, projects: [LinuxHostProject], archive: LinuxHostArchive, client: LinuxHostTrustRequest) {
        self.destination = destination
        self.destinationRoot = destinationRoot
        self.projects = projects
        self.archive = archive
        self.client = client
    }
}

public struct LinuxHostSetupProgress: Sendable, Equatable {
    public let message: String
    public let completed: Int
    public let total: Int

    public init(message: String, completed: Int, total: Int) {
        self.message = message
        self.completed = completed
        self.total = total
    }
}

public struct LinuxHostSetupResult: Sendable, Equatable {
    public let identity: LinuxHostIdentity
    public let openSSH: LinuxHostResolvedSSH
    public let destination: LinuxHostDestination
    public let projectPaths: [String]
}

public enum LinuxHostSetupError: Error, LocalizedError, Sendable, Equatable {
    case invalidPlan(String)
    case remoteFailure(String)

    public static func message(for error: any Error) -> String {
        guard let error = error as? CLIError else { return error.localizedDescription }
        switch error {
        case .notFound(let command): return "Install \(command) on this Mac, then retry setup."
        case .timedOut(let command, _): return "\(command) timed out. Check the network or repository size, then retry setup."
        case .launchFailed(let command, let message): return "Could not launch \(command). \(message)"
        case .nonZeroExit(let command, _, let stderr): return "\(command) failed. Check the selected branch and repository, then retry.\n\(stderr)"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidPlan(let message): return message
        case .remoteFailure(let stderr):
            if stderr.contains("Host key verification failed") || stderr.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                return "OpenSSH could not verify the host key. Run ssh to this destination in Terminal, verify its fingerprint, and resolve the known_hosts entry before retrying.\n\(stderr)"
            }
            if stderr.contains("Permission denied") || stderr.contains("Too many authentication failures") {
                return "OpenSSH authentication failed. Test ssh to this destination in Terminal and load your key into ssh-agent before retrying.\n\(stderr)"
            }
            if stderr.contains("GRAFTTY_MISSING:") {
                return "The Linux host is missing a dependency or an active systemd user session. Install the named tool or enable the user's systemd session, then retry.\n\(stderr)"
            }
            if stderr.contains("GRAFTTY_REPOSITORY_CONFLICT") {
                return "The destination repository is unrelated, dirty, or has changed since import. Choose another destination directory or resolve its changes before retrying.\n\(stderr)"
            }
            if stderr.contains("GRAFTTY_IMPORT_LOCKED") {
                return "Another import may be running. Wait for it to finish. After an interrupted import, inspect and remove the named .graftty-import-lock directory before retrying.\n\(stderr)"
            }
            return "Linux setup failed. Check the destination, network, and error below, then retry.\n\(stderr)"
        }
    }
}
