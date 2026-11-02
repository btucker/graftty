import Foundation
import GrafttyKit

@MainActor
enum FilePreviewRequest {
    static func handle(path: String, targets: [String], paneSessionName: String?,
                       state: () -> AppState, terminalManager: TerminalManager, store: RemoteOpenStore = .shared) async -> ResponseMessage {
        guard let scope = ImagePreviewRouting.scope(path: path, paneSessionName: paneSessionName, state: state()) else {
            return .error("The originating pane is unavailable. Run graftty preview from a tracked pane.")
        }
        let previews = ImagePreviewStore.shared
        let generation = previews.beginRequest(for: scope.pane)
        defer { previews.finishRequest(generation, for: scope.pane) }
        do {
            let urls = targets.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            let snapshots = try await Task.detached(priority: .userInitiated) {
                try FilePreviewLoader.snapshots(urls)
            }.value
            guard previews.isCurrent(generation, for: scope.pane) else {
                return .error("This preview request was replaced or dismissed.")
            }
            guard ImagePreviewRouting.scope(path: scope.worktreePath, paneSessionName: scope.sessionName, state: state()) == scope else {
                return .error("The originating pane is no longer available.")
            }
            let ownership = terminalManager.displayOwnershipStore?.snapshot(sessionName: scope.sessionName)
            let recipient = ownership?.ownerClientID.flatMap(BrowserTunnelApprovalStore.deviceID(for:))
            if ownership?.ownerKind == .ios, recipient == nil {
                return .error("The mobile pane owner could not be identified. Take Control in Graftty Mobile and retry graftty preview.")
            }
            let published = try await store.publishPreviews(snapshots, worktree: scope.worktreePath,
                paneSessionName: scope.sessionName, ownerDeviceID: recipient, previewRevision: generation.sequence)
            switch ImagePreviewRouting.destination(ownerKind: ownership?.ownerKind,
                                                   macIsFollower: terminalManager.handle(for: scope.pane) == nil || terminalManager.canTakeDisplayControl(for: scope.pane)) {
            case .mobile:
                guard let ownerClientID = ownership?.ownerClientID,
                      let deviceID = BrowserTunnelApprovalStore.deviceID(for: ownerClientID) else {
                    return .error("The mobile pane owner could not be identified. Take Control in Graftty Mobile and retry graftty preview.")
                }
                // The owner receives the automatic offer; every authorized viewer can browse the catalog.
                let offers = published
                guard recipient == deviceID else { return .error("The preview recipient changed. Open it from the worktree preview menu.") }
                let currentOwnership = terminalManager.displayOwnershipStore?.snapshot(sessionName: scope.sessionName)
                guard previews.isCurrent(generation, for: scope.pane),
                      ImagePreviewRouting.scope(path: scope.worktreePath, paneSessionName: scope.sessionName, state: state()) == scope,
                      currentOwnership?.ownerClientID == ownership?.ownerClientID,
                      currentOwnership?.ownerKind == .ios,
                      currentOwnership?.epoch == ownership?.epoch else {
                    for offer in offers { await store.withdraw(id: offer.id, worktree: scope.worktreePath) }
                    return .error("The preview request or its display leader changed before delivery. Retry graftty preview.")
                }
            case .mac:
                let files = try await Task.detached(priority: .userInitiated) {
                    try zip(snapshots, urls).map { try FilePreviewFile($0.0, sourceURL: $0.1) }
                }.value
                let currentOwnership = terminalManager.displayOwnershipStore?.snapshot(sessionName: scope.sessionName)
                guard previews.isCurrent(generation, for: scope.pane),
                      ImagePreviewRouting.scope(path: scope.worktreePath, paneSessionName: scope.sessionName, state: state()) == scope,
                      currentOwnership?.ownerClientID == ownership?.ownerClientID,
                      currentOwnership?.epoch == ownership?.epoch,
                      ImagePreviewRouting.destination(ownerKind: currentOwnership?.ownerKind,
                          macIsFollower: terminalManager.handle(for: scope.pane) == nil || terminalManager.canTakeDisplayControl(for: scope.pane)) == .mac else {
                    return .error("The preview request or its display leader changed before delivery. Retry graftty preview.")
                }
                let entry = FilePreviewHistory.shared.record(files: files, pane: scope.pane, worktreePath: scope.worktreePath,
                    id: published.first?.previewGroupID ?? UUID())
                previews.dismiss(scope.pane)
                FilePreviewWindows.shared.show(entry, activate: false, resolveInlineWorktree: { [weak terminalManager] pane in
                    terminalManager?.worktreePath(for: pane)
                })
            case .unavailable:
                // Saved for manual browsing on every client even without a native display leader.
                break
            }
            return .ok
        } catch { return .error(error.localizedDescription) }
    }
}
