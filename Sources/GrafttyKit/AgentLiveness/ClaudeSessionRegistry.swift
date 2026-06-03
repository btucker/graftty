import Foundation
import Observation
import os

/// Polls `claude agents --json` (+ a batched `ps eww` to recover each
/// session's inherited `ZMX_SESSION`) and exposes per-pane busy/idle.
/// Read-only with respect to Claude Code. Modeled on `PRStatusStore`.
@MainActor
@Observable
public final class ClaudeSessionRegistry {
    public private(set) var livenessBySession: [String: AgentLiveness] = [:]

    /// Fired on the main actor after each poll that *changes* liveness, with
    /// the new map. The app wires this to apply the AGENT-3.4 resume rule to
    /// `AppState` at the model layer — so every consumer (Mac sidebar AND the
    /// iPad/web `WorktreePanes` snapshot, which reads attention straight from
    /// the model) sees busy panes with no stale agent-stop pill, even when no
    /// window is on screen. Keeping this rule in a view modifier left the
    /// remote/headless surface inconsistent.
    @ObservationIgnored public var onLivenessChange: (([String: AgentLiveness]) -> Void)?

    @ObservationIgnored private let executor: CLIExecutor
    @ObservationIgnored private let claudePath: String
    @ObservationIgnored private var ticker: PollingTickerLike?
    @ObservationIgnored internal var generation = 0
    @ObservationIgnored private let logger =
        Logger(subsystem: "com.btucker.graftty", category: "ClaudeSessionRegistry")

    public init(executor: CLIExecutor = CLIRunner(), claudePath: String = "claude") {
        self.executor = executor
        self.claudePath = claudePath
    }

    /// Begin polling on the supplied ticker (the app wires the real
    /// `PollingTicker`; tests call `refresh()` directly).
    public func start(ticker: PollingTickerLike) {
        stop()
        self.ticker = ticker
        ticker.start { [weak self] in await self?.refresh() }
    }

    public func stop() { ticker?.stop(); ticker = nil }

    /// One poll cycle. A stuck/superseded poll's late write is dropped via
    /// the generation token. Failure collapses to an empty map (AGENT-2.3).
    public func refresh() async {
        generation += 1
        let mine = generation
        let map = await Self.poll(executor: executor, claudePath: claudePath, logger: logger)
        guard mine == generation else { return }
        if livenessBySession != map {
            livenessBySession = map
            onLivenessChange?(map)
        }
    }

    private static func poll(
        executor: CLIExecutor, claudePath: String, logger: Logger
    ) async -> [String: AgentLiveness] {
        do {
            let agents = try await executor.capture(
                command: claudePath, args: ["agents", "--json"], at: ".")
            guard agents.exitCode == 0 else { return [:] }
            let pids = AgentLivenessParsing.pids(agentsJSON: agents.stdout)
            guard !pids.isEmpty else { return [:] }
            let ps = try await executor.capture(
                command: "ps",
                args: ["eww", "-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")],
                at: ".")
            return AgentLivenessParsing.liveness(agentsJSON: agents.stdout, psOutput: ps.stdout)
        } catch {
            logger.debug("claude agents poll failed: \(String(describing: error))")
            return [:]
        }
    }
}
