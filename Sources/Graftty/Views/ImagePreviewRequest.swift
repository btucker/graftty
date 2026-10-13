import Foundation
import GrafttyKit

@MainActor
enum ImagePreviewRequest {
    static func handle(path: String, target: String, paneSessionName: String?,
                       state: () -> AppState, terminalManager: TerminalManager) async -> ResponseMessage {
        guard let scope = ImagePreviewRouting.scope(path: path, paneSessionName: paneSessionName, state: state()) else {
            return .error("The originating pane is unavailable. Run graftty image from a tracked pane.")
        }
        let previews = ImagePreviewStore.shared
        let generation = previews.beginRequest(for: scope.pane)
        defer { previews.finishRequest(generation, for: scope.pane) }
        do {
            let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath).standardizedFileURL
            let snapshot = try await Task.detached(priority: .userInitiated) {
                try ImagePreviewLoader.snapshot(url)
            }.value
            guard previews.isCurrent(generation, for: scope.pane) else {
                return .error("This image request was replaced or dismissed.")
            }
            guard ImagePreviewRouting.scope(path: scope.worktreePath, paneSessionName: scope.sessionName, state: state()) == scope else {
                return .error("The originating pane is no longer available.")
            }
            let ownership = terminalManager.displayOwnershipStore?.snapshot(sessionName: scope.sessionName)
            switch ImagePreviewRouting.destination(ownerKind: ownership?.ownerKind,
                                                   macIsFollower: terminalManager.handle(for: scope.pane) == nil || terminalManager.canTakeDisplayControl(for: scope.pane)) {
            case .mobile:
                let offer = try await RemoteOpenStore.shared.offerSnapshot(bytes: snapshot.bytes, filename: url.lastPathComponent,
                                                                  worktree: scope.worktreePath, paneSessionName: scope.sessionName,
                                                                  previewRevision: generation.sequence)
                let currentOwnership = terminalManager.displayOwnershipStore?.snapshot(sessionName: scope.sessionName)
                guard previews.isCurrent(generation, for: scope.pane),
                      ImagePreviewRouting.scope(path: scope.worktreePath, paneSessionName: scope.sessionName, state: state()) == scope,
                      currentOwnership?.ownerClientID == ownership?.ownerClientID,
                      currentOwnership?.ownerKind == .ios,
                      currentOwnership?.epoch == ownership?.epoch else {
                    await RemoteOpenStore.shared.withdraw(id: offer.id, worktree: scope.worktreePath)
                    return .error("The image request or its display leader changed before delivery. Retry graftty image.")
                }
            case .mac:
                previews.present(snapshot.image, filename: url.lastPathComponent, sourceURL: url, for: scope.pane)
            case .unavailable:
                return .error("The pane's display leader cannot receive a native image preview. Take Control on this Mac or use graftty open.")
            }
            return .ok
        } catch { return .error(error.localizedDescription) }
    }
}
