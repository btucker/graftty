import Foundation
import GrafttyKit

@MainActor
enum FilePreviewRequest {
    static func handle(path: String, targets: [String], paneSessionName: String?,
                       state: () -> AppState, terminalManager: TerminalManager) async -> ResponseMessage {
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
            switch ImagePreviewRouting.destination(ownerKind: ownership?.ownerKind,
                                                   macIsFollower: terminalManager.handle(for: scope.pane) == nil || terminalManager.canTakeDisplayControl(for: scope.pane)) {
            case .mobile:
                guard let ownerClientID = ownership?.ownerClientID,
                      let deviceID = BrowserTunnelApprovalStore.deviceID(for: ownerClientID) else {
                    return .error("The mobile pane owner could not be identified. Take Control in Graftty Mobile and retry graftty preview.")
                }
                let offers = try await RemoteOpenStore.shared.offerPreviews(snapshots, worktree: scope.worktreePath,
                    paneSessionName: scope.sessionName, previewRevision: generation.sequence, ownerDeviceID: deviceID)
                let currentOwnership = terminalManager.displayOwnershipStore?.snapshot(sessionName: scope.sessionName)
                guard previews.isCurrent(generation, for: scope.pane),
                      ImagePreviewRouting.scope(path: scope.worktreePath, paneSessionName: scope.sessionName, state: state()) == scope,
                      currentOwnership?.ownerClientID == ownership?.ownerClientID,
                      currentOwnership?.ownerKind == .ios,
                      currentOwnership?.epoch == ownership?.epoch else {
                    for offer in offers { await RemoteOpenStore.shared.withdraw(id: offer.id, worktree: scope.worktreePath) }
                    return .error("The preview request or its display leader changed before delivery. Retry graftty preview.")
                }
            case .mac:
                let files = try zip(snapshots, urls).map { try FilePreviewFile($0.0, sourceURL: $0.1) }
                previews.present(files: files, for: scope.pane)
            case .unavailable:
                return .error("The pane's display leader cannot receive a native preview. Take Control on this Mac or use graftty open.")
            }
            return .ok
        } catch { return .error(error.localizedDescription) }
    }
}
