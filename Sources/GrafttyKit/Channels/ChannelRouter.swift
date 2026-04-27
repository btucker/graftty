import Foundation
import Observation

/// Owns the channels socket server and the worktreePath → Connection map.
/// Fans out transition events to the matching subscriber; broadcasts
/// prompt updates (type=instructions) to all.
@MainActor
@Observable
public final class ChannelRouter {
    @ObservationIgnored private let server: ChannelSocketServer
    @ObservationIgnored private nonisolated(unsafe) let promptProvider: (_ worktreePath: String) -> String
    private var subscribers: [String: ChannelSocketServer.Connection] = [:]

    public var subscriberCount: Int { subscribers.count }

    /// When false, `dispatch` and `broadcastInstructions` become no-ops.
    /// Subscribers remain connected. Mirrors the Settings enable toggle.
    public var isEnabled: Bool = true

    public init(socketPath: String, promptProvider: @escaping (_ worktreePath: String) -> String) {
        self.server = ChannelSocketServer(socketPath: socketPath)
        self.promptProvider = promptProvider

        server.onSubscribe = { [weak self] message, conn in
            guard let self = self else { return }
            // ChannelSocketServer now calls us on its connection thread, so
            // we can (a) send the initial instructions immediately without
            // waiting for main-actor availability and (b) hop to the main
            // actor for the subscribers-map mutation where router state lives.
            // Extract the worktree path from the subscribe message so the
            // provider can render per-worktree instructions (TEAM-3.3).
            let worktreePath: String
            if case let .subscribe(wt, _) = message { worktreePath = wt } else { worktreePath = "" }
            let initial = ChannelServerMessage.event(
                type: ChannelEventType.instructions,
                attrs: [:],
                body: self.promptProvider(worktreePath)
            )
            try? conn.write(initial)
            Task { @MainActor [weak self] in self?.onSubscribe(message: message, conn: conn) }
        }
        server.onDisconnect = { [weak self] conn in
            Task { @MainActor [weak self] in self?.onDisconnect(conn: conn) }
        }
    }

    public func start() throws { try server.start() }
    public func stop() {
        server.stop()
        subscribers.removeAll()
    }

    /// Route a transition event to the matching subscriber, if any.
    public func dispatch(worktreePath: String, message: ChannelServerMessage) {
        guard isEnabled else { return }
        guard let conn = subscribers[worktreePath] else { return }
        writeOrPrune(conn: conn, message: message, worktreePath: worktreePath)
    }

    /// Dispatches a `ChannelServerMessage` addressed to the lead worktree of
    /// `repo`, per TEAM-2.3 (lead = worktree where path == repo.path).
    public func dispatchToLead(of repo: RepoEntry, message: ChannelServerMessage) {
        guard isEnabled else { return }
        dispatch(worktreePath: repo.path, message: message)
    }

    /// Fan out the current prompt as a type=instructions event to every
    /// subscriber. Each subscriber receives a prompt rendered for its own
    /// worktree path, so team-aware instructions differ per member (TEAM-3.3).
    /// Called after the Settings prompt-edit debounce fires.
    public func broadcastInstructions() {
        guard isEnabled else { return }

        // Collect dead subscribers and prune after iteration — Swift
        // dictionary iteration is snapshot-based so removing mid-loop
        // wouldn't crash, but two-phase is more explicit and robust to
        // future refactors that change iteration semantics.
        var dead: [String] = []
        for (worktreePath, conn) in subscribers {
            let body = promptProvider(worktreePath)
            let message = ChannelServerMessage.event(
                type: ChannelEventType.instructions, attrs: [:], body: body
            )
            do {
                try conn.write(message)
            } catch {
                dead.append(worktreePath)
            }
        }
        for worktree in dead {
            subscribers.removeValue(forKey: worktree)
        }
    }

    // MARK: private

    private func onSubscribe(message: ChannelClientMessage, conn: ChannelSocketServer.Connection) {
        guard case let .subscribe(worktree, _) = message else { return }
        subscribers[worktree] = conn
        // The initial `instructions` event was already written synchronously
        // from the server's connection thread in the init closure.
    }

    private func onDisconnect(conn: ChannelSocketServer.Connection) {
        subscribers = subscribers.filter { $0.value !== conn }
    }

    private func writeOrPrune(
        conn: ChannelSocketServer.Connection,
        message: ChannelServerMessage,
        worktreePath: String
    ) {
        do {
            try conn.write(message)
        } catch {
            subscribers.removeValue(forKey: worktreePath)
        }
    }
}
