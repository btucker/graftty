import Foundation
import GrafttyProtocol
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("Remote worktree one-hop relay")
@MainActor
struct RemoteWorktreeRelayRouterTests {
    @Test("""
    @spec REMOTE-13.1: While a Mac shares worktrees from a directly connected \
    Remote Mac, the application shall preserve the remote split layout, replace \
    resource identifiers with opaque one-hop aliases, and exclude any row that \
    was already relayed by the downstream Mac.
    """)
    func promotesOnlyDirectRowsAndPreservesLayout() throws {
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        let router = RemoteWorktreeRelayRouter()
        let directLayout = PaneLayoutNode.split(
            direction: .horizontal,
            ratio: 0.37,
            left: .leaf(
                sessionName: "left-pane",
                title: "editor",
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            ),
            right: .split(
                direction: .vertical,
                ratio: 0.61,
                left: .leaf(
                    sessionName: "top-pane",
                    title: "tests",
                    attentionText: nil,
                    isBusy: true,
                    attentionSource: nil
                ),
                right: .leaf(
                    sessionName: "bottom-pane",
                    title: "agent",
                    attentionText: "Claude needs input",
                    isBusy: false,
                    attentionSource: .agentStop
                )
            )
        )
        let direct = worktree(
            path: "/repos/one/.worktrees/feature",
            repositoryID: "/repos/one",
            layout: directLayout,
            origin: WorktreeOrigin(
                deviceID: remote.id,
                deviceLabel: remote.label,
                relayDepth: 0
            )
        )
        let alreadyRelayed = worktree(
            path: "relay-worktree-from-elsewhere",
            repositoryID: "relay-repository-from-elsewhere",
            layout: directLayout,
            origin: WorktreeOrigin(
                deviceID: RemoteDeviceID(value: "third-mac"),
                deviceLabel: "Third Mac",
                relayDepth: 1
            )
        )

        let promoted = router.promotedWorktrees(
            snapshots: [identity: [direct, alreadyRelayed]],
            remoteMacs: [remote]
        )

        let row = try #require(promoted.first)
        #expect(promoted.count == 1)
        #expect(row.path.hasPrefix("relay-worktree-"))
        #expect(row.repositoryID?.hasPrefix("relay-repository-") == true)
        #expect(row.route?.worktreeID == row.path)
        #expect(row.route?.repositoryID == row.repositoryID)
        #expect(row.origin?.relayDepth == 1)
        #expect(row.layout?.leaves.map(\.title) == ["editor", "tests", "agent"])

        guard case let .split(direction, ratio, _, right)? = row.layout else {
            Issue.record("expected the outer split to be preserved")
            return
        }
        #expect(direction == .horizontal)
        #expect(ratio == 0.37)
        guard case let .split(nestedDirection, nestedRatio, _, _) = right else {
            Issue.record("expected the nested split to be preserved")
            return
        }
        #expect(nestedDirection == .vertical)
        #expect(nestedRatio == 0.61)

        let paneAliases = try #require(row.layout?.leaves)
        #expect(paneAliases.allSatisfy {
            $0.sessionName.hasPrefix("relay-pane-")
        })
        #expect(
            router.resolvePane(paneAliases[0].sessionName)
                == RelayedPaneTarget(
                    identity: identity,
                    sessionName: "left-pane"
                )
        )
        #expect(
            router.resolveWorktree(row.path)
                == RelayedWorktreeTarget(
                    identity: identity,
                    path: direct.path
                )
        )
    }

    @Test("""
    @spec REMOTE-13.2: When GrafttyMobile connects to a Mac that has a live \
    direct Remote Mac connection, the application shall expose that Remote \
    Mac's repositories and worktrees as depth-one rows whose repository \
    aliases match across listing and creation routes.
    """)
    func repositoryAndWorktreeAliasesMatch() throws {
        let remote = try makeRemoteMac()
        let identity = RemoteMacIdentity(remote)
        let router = RemoteWorktreeRelayRouter()
        let row = worktree(
            path: "/repos/one/.worktrees/feature",
            repositoryID: "/repos/one",
            layout: nil,
            origin: nil
        )
        let promotedWorktree = try #require(
            router.promotedWorktrees(
                snapshots: [identity: [row]],
                remoteMacs: [remote]
            ).first
        )
        let repository = RemoteRepositoryInfo(
            id: "/repos/one",
            displayName: "one",
            origin: nil,
            defaultBranchStatus: nil,
            branches: []
        )
        let promotedRepository = try #require(
            router.promotedRepositories(
                [repository],
                from: remote
            ).first
        )

        #expect(promotedWorktree.repositoryID == promotedRepository.id)
        #expect(promotedWorktree.route?.repositoryID == promotedRepository.id)
        #expect(
            router.resolveRepository(promotedRepository.id)
                == RelayedRepositoryTarget(
                    identity: identity,
                    repositoryID: repository.id
                )
        )
    }

    @Test("""
    @spec REMOTE-13.4: When a user selects a Remote Mac worktree, the \
    application shall project the entire remote split tree with the original \
    axes and ratios, rather than opening only the selected pane.
    """)
    func detailProjectionPreservesFullSplitTree() {
        let first = PaneSlotID()
        let second = PaneSlotID()
        let third = PaneSlotID()
        let slots = [
            "one": first,
            "two": second,
            "three": third,
        ]
        let layout = PaneLayoutNode.split(
            direction: .vertical,
            ratio: 0.4,
            left: .leaf(
                sessionName: "one",
                title: "one",
                attentionText: nil,
                isBusy: false,
                attentionSource: nil
            ),
            right: .split(
                direction: .horizontal,
                ratio: 0.7,
                left: .leaf(
                    sessionName: "two",
                    title: "two",
                    attentionText: nil,
                    isBusy: false,
                    attentionSource: nil
                ),
                right: .leaf(
                    sessionName: "three",
                    title: "three",
                    attentionText: nil,
                    isBusy: false,
                    attentionSource: nil
                )
            )
        )

        let projected = SplitTree(root: RemotePaneLayoutProjection.node(
            from: layout,
            slotForSession: { slots[$0]! }
        ))

        #expect(projected.allLeaves == [first, second, third])
        guard case let .split(outer)? = projected.root else {
            Issue.record("expected outer split")
            return
        }
        #expect(outer.direction == .vertical)
        #expect(outer.ratio == 0.4)
        guard case let .split(inner) = outer.right else {
            Issue.record("expected inner split")
            return
        }
        #expect(inner.direction == .horizontal)
        #expect(inner.ratio == 0.7)
    }

    private func makeRemoteMac() throws -> RemoteMac {
        RemoteMac(
            id: RemoteDeviceID(value: "studio-mac"),
            label: "Studio Mac",
            fingerprint: try RemoteIdentityFingerprint(
                rawBytes: Data(repeating: 0x41, count: 32)
            )
        )
    }

    private func worktree(
        path: String,
        repositoryID: String,
        layout: PaneLayoutNode?,
        origin: WorktreeOrigin?
    ) -> WorktreePanes {
        WorktreePanes(
            path: path,
            displayName: "feature",
            repoDisplayName: "one",
            repositoryID: repositoryID,
            displayBranch: "feature",
            state: .running,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: layout,
            origin: origin
        )
    }
}
