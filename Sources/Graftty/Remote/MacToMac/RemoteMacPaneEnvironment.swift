import Foundation
import GrafttyProtocol
import GrafttyRemoteClient

protocol RemoteMacPaneEnvironmentHost: PanesStateDriverMaking {
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
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void = { _ in },
        onClosed: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> RemoteMacPaneEnvironment {
        guard let remoteHost else { return .empty }

        var worktreePanesStore: WorktreePanesStore?
        do {
            let panesStore = try await PanesStateSubscription.open(
                on: remoteHost,
                onSnapshot: onSnapshot,
                onClosed: onClosed
            )
            worktreePanesStore = panesStore

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
