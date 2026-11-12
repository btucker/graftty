import Testing
@testable import GrafttyProtocol

struct WorktreeDeleteAnchorTests {
    private func row(_ name: String, on device: String) -> WorktreePanes {
        WorktreePanes(path: "/repo/\(name)", displayName: name, repoDisplayName: "app", displayBranch: name,
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            origin: WorktreeOrigin(deviceID: RemoteDeviceID(value: device), deviceLabel: device, relayDepth: 0),
            sidebar: .init(id: "\(device):app:\(name)", projectID: "\(device):app"))
    }

    @Test("@spec IOS-13.29: When the user deletes or dismisses a worktree from its row or tile on iPhone or iPad, the application shall anchor the confirmation to that row or tile, and to no other row, including a same-path worktree on another host.")
    func confirmationAnchorsToTheChosenRowOnly() {
        let fix = row("fix", on: "mac"), other = row("other", on: "mac"), elsewhere = row("fix", on: "box")
        #expect(MergedWorktreeList.isSameWorktree(fix, fix))
        #expect(!MergedWorktreeList.isSameWorktree(fix, other))
        #expect(!MergedWorktreeList.isSameWorktree(fix, elsewhere), "The same path on another host is a different row")
        #expect(!MergedWorktreeList.isSameWorktree(nil, fix))
    }
}
