// Sources/GrafttyKit/Ports/LsofRunner.swift
import Foundation

public protocol LsofRunner: Sendable {
    /// Returns the raw stdout of `lsof -nP -iTCP -sTCP:LISTEN -p <pids>`,
    /// or nil if the command failed (non-zero exit, missing binary, etc.).
    /// PIDs is comma-joined per lsof's `-p` syntax.
    func run(pids: String) async -> String?
}

public struct SystemLsofRunner: LsofRunner {
    public init() {}

    public func run(pids: String) async -> String? {
        guard !pids.isEmpty else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-p", pids]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
