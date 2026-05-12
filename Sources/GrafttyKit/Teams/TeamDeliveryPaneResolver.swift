import Darwin
import Foundation

public protocol ProcessCommandReading: Sendable {
    func commandLine(pid: pid_t) -> String?
    func commandLines(pids: [pid_t]) -> [pid_t: String]
}

public extension ProcessCommandReading {
    func commandLines(pids: [pid_t]) -> [pid_t: String] {
        Dictionary(uniqueKeysWithValues: pids.compactMap { pid in
            commandLine(pid: pid).map { (pid, $0) }
        })
    }
}

public struct ProcessCommandReader: ProcessCommandReading {
    public init() {}

    public func commandLine(pid: pid_t) -> String? {
        commandLines(pids: [pid])[pid]
    }

    public func commandLines(pids: [pid_t]) -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-p", pids.map(String.init).joined(separator: ","),
            "-o", "pid=",
            "-o", "command=",
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return [:]
        }

        guard process.terminationStatus == 0 else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.parsePSOutput(text)
    }

    static func parsePSOutput(_ text: String) -> [pid_t: String] {
        var commands: [pid_t: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                continue
            }
            let pidText = String(line[..<separator])
            let command = line[separator...].trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(pidText), !command.isEmpty else { continue }
            commands[pid] = command
        }
        return commands
    }
}

public struct TeamDeliveryPaneResolver: Sendable {
    private let processTree: any ProcessTreeWalking
    private let commandReader: any ProcessCommandReading

    public init(
        processTree: any ProcessTreeWalking,
        commandReader: any ProcessCommandReading
    ) {
        self.processTree = processTree
        self.commandReader = commandReader
    }

    public func paneIDs(
        records: [TeamPresenceRecord],
        worktree: String,
        runtime: TeamHookRuntime,
        paneIDForSessionName: (String) -> UUID?,
        shellPIDForPaneID: (UUID) -> pid_t?
    ) -> [UUID] {
        var seen: Set<UUID> = []
        var resolved: [UUID] = []
        for record in records where record.worktree == worktree && record.runtime == runtime {
            guard let sessionName = record.paneSessionName,
                  let paneID = paneIDForSessionName(sessionName),
                  !seen.contains(paneID),
                  let shellPID = shellPIDForPaneID(paneID),
                  runtimeIsRunning(runtime, underShellPID: shellPID) else {
                continue
            }
            seen.insert(paneID)
            resolved.append(paneID)
        }
        return resolved
    }

    private func runtimeIsRunning(
        _ runtime: TeamHookRuntime,
        underShellPID shellPID: pid_t
    ) -> Bool {
        let descendants = processTree.descendants(of: shellPID)
        let commandsByPID = commandReader.commandLines(pids: descendants)
        return commandsByPID.values.contains { command in
            Self.commandLine(command, matches: runtime)
        }
    }

    static func commandLine(_ commandLine: String, matches runtime: TeamHookRuntime) -> Bool {
        let tokens = commandLine
            .split { $0 == " " || $0 == "\t" || $0 == "\n" }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }
        guard let executable = tokens.first else { return false }

        if isRuntimeExecutable(executable, runtime: runtime) {
            return true
        }

        let executableName = basename(executable)
        let scriptWrappers: Set<String> = ["node", "bun", "deno", "tsx"]
        guard scriptWrappers.contains(executableName) else { return false }

        return tokens.dropFirst().contains { token in
            isRuntimeExecutable(token, runtime: runtime)
        }
    }

    private static func isRuntimeExecutable(_ token: String, runtime: TeamHookRuntime) -> Bool {
        let name = basename(token)
        switch runtime {
        case .codex:
            return name == "codex"
        case .claude:
            return name == "claude" || name == "claude-code"
        }
    }

    private static func basename(_ token: String) -> String {
        String(token.split(separator: "/").last ?? Substring(token))
    }
}
