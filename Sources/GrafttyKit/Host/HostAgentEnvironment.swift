import Foundation

/// Environment shared by Linux panes and provider setup commands.
enum HostAgentEnvironment {
    static func path(inheritedPath: String, home: String, loginPath: String? = nil) -> String {
        let existing = loginPath.flatMap { $0.isEmpty ? nil : $0 } ?? inheritedPath
        let local = URL(fileURLWithPath: home).appendingPathComponent(".local/bin").path
        guard !existing.components(separatedBy: ":").contains(local) else { return existing }
        return existing.isEmpty ? local : existing + ":" + local
    }

    /// File-backed output prevents profile background jobs holding a pipe open.
    /// Probe once per plugin setup, so changes to profile-managed tools are seen.
    static func loginPath(shellPath: String, home: String, timeout: TimeInterval = 15) async throws -> String? {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-agent-env-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("path")
        let runner = LinuxHostSSHRunner(executable: shellPath, timeout: timeout, directory: home)
        do {
            let result = try await runner.capture(arguments: ["-ilc", "/usr/bin/printenv PATH > " + LinuxHostScripts.quote(output.path)], inputFile: nil)
            guard result.exitCode == 0, let data = try? Data(contentsOf: output),
                  let raw = String(data: data, encoding: .utf8) else { return nil }
            let value = raw.hasSuffix("\n") ? String(raw.dropLast()) : raw
            return value.isEmpty ? nil : value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    static func executor(path: String, base: any CLIExecutor) -> any CLIExecutor {
        HostAgentPathExecutor(path: path, base: base)
    }
}

private struct HostAgentPathExecutor: CLIExecutor {
    let path: String
    let base: any CLIExecutor

    func run(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await run(command: command, args: args, at: directory, timeout: nil)
    }

    func capture(command: String, args: [String], at directory: String) async throws -> CLIOutput {
        try await capture(command: command, args: args, at: directory, timeout: nil)
    }

    func run(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        try await base.run(command: "/usr/bin/env", args: ["PATH=" + path, command] + args, at: directory, timeout: timeout)
    }

    func capture(command: String, args: [String], at directory: String, timeout: Duration?) async throws -> CLIOutput {
        try await base.capture(command: "/usr/bin/env", args: ["PATH=" + path, command] + args, at: directory, timeout: timeout)
    }
}
