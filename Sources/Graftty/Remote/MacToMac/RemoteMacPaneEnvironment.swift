import Foundation
import GrafttyProtocol
import GrafttyRemoteClient

protocol RemoteMacPaneEnvironmentHost: Sendable {
    func makePanesStateDriver(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) async throws -> any PanesStateChannelDriver

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver
}

struct RemoteMacPaneEnvironment: Equatable, Sendable {
    let worktreePanesStore: WorktreePanesStore?
    let paneControlClient: PaneControlClient?

    static let empty = RemoteMacPaneEnvironment(
        worktreePanesStore: nil,
        paneControlClient: nil
    )

    static func == (lhs: RemoteMacPaneEnvironment, rhs: RemoteMacPaneEnvironment) -> Bool {
        lhs.worktreePanesStore == nil
            && rhs.worktreePanesStore == nil
            && lhs.paneControlClient == nil
            && rhs.paneControlClient == nil
    }

    static func build(
        remoteHost: RemoteMacPaneEnvironmentHost?,
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void = { _ in }
    ) async -> RemoteMacPaneEnvironment {
        guard let remoteHost else { return .empty }

        do {
            let panesDriver = try await remoteHost.makePanesStateDriver(
                onSnapshot: onSnapshot,
                onClosed: { _ in }
            )
            let worktreePanesStore = WorktreePanesStore(driver: panesDriver)
            if let panesClient = panesDriver as? PanesStateChannelClient {
                panesClient.setCallbacks(
                    onSnapshot: { [weak worktreePanesStore] snapshot in
                        await worktreePanesStore?.applySnapshot(snapshot)
                        await onSnapshot(snapshot)
                    },
                    onClosed: { [weak worktreePanesStore] reason in
                        await worktreePanesStore?.markClosed(reason: reason)
                    }
                )
            }
            try await worktreePanesStore.subscribe()

            let controlDriver = try await remoteHost.makePaneControlDriver()
            let paneControlClient = PaneControlClient(driver: controlDriver)
            try await paneControlClient.open()

            return RemoteMacPaneEnvironment(
                worktreePanesStore: worktreePanesStore,
                paneControlClient: paneControlClient
            )
        } catch {
            return .empty
        }
    }
}
