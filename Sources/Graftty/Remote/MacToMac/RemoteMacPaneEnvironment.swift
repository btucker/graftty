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

struct RemoteMacPaneEnvironment: Sendable {
    let worktreePanesStore: WorktreePanesStore?
    let paneControlClient: PaneControlClient?

    static let empty = RemoteMacPaneEnvironment(
        worktreePanesStore: nil,
        paneControlClient: nil
    )

    var isEmpty: Bool {
        worktreePanesStore == nil && paneControlClient == nil
    }

    func close() async {
        await worktreePanesStore?.unsubscribe()
        await paneControlClient?.close()
    }

    static func build(
        remoteHost: RemoteMacPaneEnvironmentHost?,
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void = { _ in }
    ) async -> RemoteMacPaneEnvironment {
        guard let remoteHost else { return .empty }

        var worktreePanesStore: WorktreePanesStore?
        do {
            let panesDriver = try await remoteHost.makePanesStateDriver(
                onSnapshot: onSnapshot,
                onClosed: { _ in }
            )
            let panesStore = WorktreePanesStore(driver: panesDriver)
            worktreePanesStore = panesStore
            if let panesClient = panesDriver as? PanesStateChannelClient {
                panesClient.setCallbacks(
                    onSnapshot: { [weak panesStore] snapshot in
                        await panesStore?.applySnapshot(snapshot)
                        await onSnapshot(snapshot)
                    },
                    onClosed: { [weak panesStore] reason in
                        await panesStore?.markClosed(reason: reason)
                    }
                )
            }
            try await panesStore.subscribe()

            let controlDriver = try await remoteHost.makePaneControlDriver()
            let paneControlClient = PaneControlClient(driver: controlDriver)
            try await paneControlClient.open()

            return RemoteMacPaneEnvironment(
                worktreePanesStore: panesStore,
                paneControlClient: paneControlClient
            )
        } catch {
            await worktreePanesStore?.unsubscribe()
            return .empty
        }
    }
}
