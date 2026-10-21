// Sources/GrafttyKit/Ports/LsofRunner.swift
import Foundation

public protocol LsofRunner: Sendable {
    /// Returns the raw stdout of `lsof -nP -iTCP -sTCP:LISTEN -p <pids>`
    /// for any exit status (lsof exits 1 when nothing matches), or nil if
    /// the command could not run (missing binary, launch failure, timeout).
    /// PIDs is comma-joined per lsof's `-p` syntax.
    func run(pids: String) async -> String?
}

public struct SystemLsofRunner: LsofRunner {
    /// Bounds each scan. `PollingTicker` awaits every tick before sleeping,
    /// so one wedged `lsof` would otherwise stall port scanning until
    /// restart (PORTS-1.6).
    static let timeout: Duration = .seconds(5)

    private let executor: CLIExecutor

    public init(executor: CLIExecutor = CLIRunner()) {
        self.executor = executor
    }

    public func run(pids: String) async -> String? {
        guard !pids.isEmpty else { return "" }
        do {
            let output = try await executor.capture(
                command: "lsof",
                // `-b` skips lsof's stat/readlink of mount points, each of
                // which otherwise waits up to lsof's own 15 s default on an
                // unreachable network mount and would exceed the timeout on
                // every scan; `-w` silences the resulting warnings.
                args: ["-b", "-w", "-nP", "-a", "-iTCP", "-sTCP:LISTEN", "-p", pids],
                at: "/",
                timeout: Self.timeout
            )
            return output.stdout
        } catch {
            return nil
        }
    }
}
