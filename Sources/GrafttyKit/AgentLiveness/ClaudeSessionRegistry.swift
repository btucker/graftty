import Foundation
import Observation
import os

/// Polls `claude agents --json` (+ a batched `ps eww` to recover each
/// session's inherited `ZMX_SESSION`) and merges provider hook activity
/// for Codex and Claude into per-pane busy/idle state.
/// Read-only with respect to Claude Code. Modeled on `PRStatusStore`.
@MainActor
@Observable
public final class ClaudeSessionRegistry {
    public private(set) var livenessBySession: [String: AgentLiveness] = [:]
    @ObservationIgnored private var polledLiveness: [String: AgentLiveness] = [:]
    @ObservationIgnored private var hookLiveness: [String: [String: AgentLiveness]] = [:]

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
    /// the generation token. Failure clears the polling result (AGENT-2.3)
    /// while independently observed provider hooks remain available.
    public func refresh() async {
        generation += 1
        let mine = generation
        let map = await Self.poll(executor: executor, claudePath: claudePath, logger: logger)
        guard mine == generation else { return }
        polledLiveness = map
        publishLiveness()
    }

    public func recordHook(runtime: TeamHookRuntime, event: TeamHookEvent,
                           sessionID: String?, paneSessionName: String,
                           attentionReason: AgentHookAttentionReason?) {
        let state: AgentLiveness
        if attentionReason != nil { state = .idle }
        else {
            switch event {
            case .sessionStart, .stop: state = .idle
            case .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure: state = .busy
            case .permissionRequest: return // Codex may approve this without involving the user.
            }
        }
        let key = runtime.rawValue + ":" + (sessionID ?? "unknown")
        hookLiveness[paneSessionName, default: [:]][key] = state == .busy ? .busy : nil
        publishLiveness()
    }

    public func removePane(_ sessionName: String) {
        generation += 1 // A poll started before command exit must not restore its busy state.
        hookLiveness[sessionName] = nil
        polledLiveness[sessionName] = nil
        publishLiveness()
    }

    private func publishLiveness() {
        var merged = polledLiveness
        for (pane, agents) in hookLiveness {
            if agents.values.contains(.busy) { merged[pane] = .busy }
            else if merged[pane] == nil { merged[pane] = .idle }
        }
        if livenessBySession != merged { livenessBySession = merged }
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
