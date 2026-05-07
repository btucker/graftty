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
        do {
            let output = try await CLIRunner().capture(
                command: "lsof",
                args: ["-nP", "-iTCP", "-sTCP:LISTEN", "-p", pids],
                at: "/"
            )
            return output.stdout
        } catch {
            return nil
        }
    }
}
