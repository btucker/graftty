import Foundation
import GrafttyKit
import GrafttyProtocol
import GrafttyRemoteClient

/// Resolves the route to a remote worktree the user picked, then selects it.
///
/// A worktree or pane may be reachable through a different host than the row
/// the user clicked, and its host may be asleep, so a selection first resolves
/// a route. `phase` is that selection's whole lifecycle; the connecting screen
/// is derived from it, so it cannot outlive the resolve it describes.
@MainActor
final class RemoteRouteSelector: ObservableObject {
    typealias Route = (mac: RemoteMac, worktree: WorktreePanes)

    enum Target: Equatable {
        case worktree
        case pane(sessionName: String)
    }

    struct Request {
        let remoteMac: RemoteMac
        let worktreePath: String
        let target: Target
    }

    private enum Phase {
        case idle
        /// `intent` holds the viewer's route recovery off until this ends.
        case resolving(Request, intent: UUID, task: Task<Void, Never>)
        /// A worktree's route could not be resolved; the user may retry.
        case failed(Request, message: String)
    }

    @Published private var phase = Phase.idle

    /// The viewer owns its selector, so the two share a lifetime.
    private unowned let viewer: RemoteWorktreeViewerController
    private let presentError: @MainActor (String) -> Void

    init(viewer: RemoteWorktreeViewerController, presentError: @escaping @MainActor (String) -> Void) {
        self.viewer = viewer
        self.presentError = presentError
    }

    /// The screen shown in place of the terminal, if any.
    var wakeFlow: WakeFlow? {
        switch phase {
        case .idle:
            nil
        case .resolving(let request, _, _):
            request.target == .worktree
                ? WakeFlow(remoteMac: request.remoteMac, worktreePath: request.worktreePath, phase: .waking) : nil
        case .failed(let request, let message):
            WakeFlow(remoteMac: request.remoteMac, worktreePath: request.worktreePath, phase: .failed(message: message))
        }
    }

    /// Selects `request`, replacing any selection still resolving.
    ///
    /// - Parameters:
    ///   - source: The row as last received. Without one, a worktree is
    ///     selected where it was clicked and a pane cannot be selected.
    ///   - willApply: Runs just before the viewer's selection changes.
    func select(_ request: Request, source: WorktreePanes?, willApply: @escaping @MainActor () -> Void) {
        cancel()
        if request.target == .worktree,
           !viewer.canSelectRemoteWorktree(request.remoteMac, worktreePath: request.worktreePath) { return }
        guard let source else {
            if request.target == .worktree {
                willApply()
                viewer.selectRemoteWorktree(request.remoteMac, worktreePath: request.worktreePath, acknowledging: true)
            }
            return
        }
        let intent = viewer.beginRouteSelection()
        let resolve = viewer.resolveWorktreeRoute
        let task = Task { [weak self] in
            let result: Result<Route, any Error>
            do {
                result = .success(try await resolve?(request.remoteMac, source, []) ?? (request.remoteMac, source))
            } catch { result = .failure(error) }
            self?.finish(request, from: source, intent: intent, result: result, willApply: willApply)
        }
        phase = .resolving(request, intent: intent, task: task)
    }

    /// Abandons a selection still resolving and removes the connecting screen.
    func cancel() {
        switch phase {
        case .idle:
            return
        case .resolving(_, let intent, let task):
            task.cancel()
            viewer.endRouteSelection(intent)
        case .failed:
            break
        }
        phase = .idle
    }

    /// Abandons a pane selection still resolving, for when the user focuses
    /// a terminal instead. A pane selection shows no connecting screen, so
    /// the terminals stay in reach. A worktree selection covers them, so a
    /// focus arriving during one is not the user's and does not end it.
    func cancelPaneSelection() {
        guard case .resolving(let request, _, _) = phase, request.target != .worktree else { return }
        cancel()
    }

    private func finish(
        _ request: Request, from source: WorktreePanes, intent: UUID,
        result: Result<Route, any Error>, willApply: @MainActor () -> Void
    ) {
        guard case .resolving(_, intent, _) = phase else { return }
        defer { viewer.endRouteSelection(intent) }
        phase = .idle
        do {
            let route = try result.get()
            switch request.target {
            case .worktree:
                // The row may have started creating or deleting while its
                // route resolved; leave the current selection in place.
                guard viewer.canSelectRemoteWorktree(route.mac, worktreePath: route.worktree.path) else { return }
                willApply()
                viewer.selectRemoteWorktree(route.mac, worktreePath: route.worktree.path, acknowledging: true)
            case .pane(let sessionName):
                guard let pane = WorktreeRouteIdentity.paneSession(sessionName, from: source, to: route.worktree) else {
                    throw RemoteMacsModel.ProjectControlError.unavailable
                }
                willApply()
                viewer.selectRemotePane(route.mac, worktreePath: route.worktree.path, sessionName: pane, acknowledging: true)
            }
        } catch is CancellationError {
            // The resolver gave up on its own; nothing to report.
        } catch {
            switch request.target {
            case .worktree: phase = .failed(request, message: error.localizedDescription)
            case .pane: presentError(error.localizedDescription)
            }
        }
    }
}
