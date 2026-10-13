import Foundation
import GrafttyProtocol

/// A user gesture retains its original route independently of mutable pane views.
struct TerminalBrowserRequest: Identifiable, Equatable {
    struct Scope: Hashable {
        let hostID: UUID
        let worktree: String
        let sessionName: String
        let ownerDeviceID: RemoteDeviceID?
    }
    let id = UUID()
    let url: URL
    let scope: Scope

    func canPresent(in current: Scope, isActive: Bool, isOwner: Bool) -> Bool {
        isActive && isOwner && scope == current && scope.ownerDeviceID != nil
            && !scope.worktree.hasPrefix("relay-worktree-")
            && ChromeTabAction.launchOffer(id: id, url: url.absoluteString).isValid
    }
}
