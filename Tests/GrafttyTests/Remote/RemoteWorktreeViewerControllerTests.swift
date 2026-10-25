import Combine
import CoreGraphics
import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing

@testable import Graftty
@testable import GrafttyKit

@Suite("Remote worktree viewer mutation queue")
@MainActor
struct RemoteWorktreeViewerControllerTests {
    @Test("@spec REMOTE-24.1: While a split request for a remote worktree is in flight, the viewer shall hold every later split, close, equalize, and resize for that worktree in one ordered queue and send the next request only after the host answers the previous one.")
    func splitInFlightSerializesLaterMutations() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")

        viewer.surfaces.send(.split(.right), from: a)
        viewer.surfaces.send(.split(.down), from: a)
        viewer.surfaces.send(.equalize, from: a)
        viewer.surfaces.send(.resize(direction: .left, amount: 3), from: a)
        viewer.surfaces.send(.close, from: a)
        await viewer.settle()
        #expect(viewer.model.requests == [.split(target: "a", direction: .right)])

        try await viewer.answer(0, .splitCreated(sessionName: "b"))
        await viewer.settle()
        #expect(viewer.model.requests.count == 2)

        try await viewer.answer(1, .splitCreated(sessionName: "c"))
        await viewer.settle()
        #expect(viewer.model.requests.count == 3)

        try await viewer.answer(2, .ok)
        await viewer.settle()
        #expect(viewer.model.requests.count == 4)

        try await viewer.answer(3, .ok)
        await viewer.settle()
        #expect(viewer.model.requests == [
            .split(target: "a", direction: .right),
            .split(target: "b", direction: .down),
            .equalize(target: "c"),
            .resize(target: "c", direction: .left, amount: 3, viewportExtent: 1000),
            .close(target: "c"),
        ])
        #expect(viewer.errors.messages.isEmpty)
    }

    @Test("@spec REMOTE-24.14: If a dispatched remote pane mutation has no reply after thirty seconds, then the viewer shall report the timeout, abandon that worktree's queued mutations, release the queue for other Macs, and ignore the expired dispatch's late result.", arguments: [HostManagedPaneCommand.split(.right), .close, .equalize, .resize(direction: .left, amount: 3)])
    func hungMutationTimesOutAndIgnoresLateReply(command: HostManagedPaneCommand) async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")
        viewer.surfaces.send(command, from: a)
        viewer.surfaces.send(.split(.down), from: a)
        await viewer.settle()

        let other = RemoteMac(
            id: RemoteDeviceID(value: "other-mac"),
            label: "Other Mac",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x33, count: 32)),
            lastKnownBaseURL: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let otherIdentity = RemoteMacIdentity(other)
        viewer.model.savedRemoteMacs.append(other)
        viewer.model.worktreePanesByRemote[otherIdentity] = viewer.model.worktreePanesByRemote[viewer.identity]
        viewer.controller.selectRemoteWorktree(other, worktreePath: ViewerHarness.path, acknowledging: false)
        await viewer.settle()
        let otherA = try viewer.terminal("a")
        viewer.surfaces.send(.equalize, from: otherA)
        await viewer.settle()
        #expect(viewer.model.requests.count == 1)

        viewer.clock.fire(.seconds(30))
        await viewer.settle()
        #expect(viewer.model.requests.count == 2)
        #expect(viewer.model.requests.last == .equalize(target: "a"))
        #expect(viewer.errors.messages.count == 1)
        #expect(viewer.errors.messages.first?.contains("timed out") == true)

        // A late result belongs to the expired dispatch, even after another
        // Mac has acquired the viewer's queue slot.
        let lateResponse: PaneControlResponse
        if case .split = command {
            lateResponse = .splitCreated(sessionName: "late")
        } else {
            lateResponse = .ok
        }
        try await viewer.answer(0, lateResponse)
        #expect(viewer.model.requests.count == 2)
        #expect(viewer.controller.selectedRemotePaneSessionName == "a")
        viewer.surfaces.send(.close, from: otherA)
        await viewer.settle()
        #expect(viewer.model.requests.count == 2)
        try await viewer.answer(1, .ok)
        #expect(viewer.model.requests.last == .close(target: "a"))
        viewer.controller.selectRemoteWorktree(viewer.mac, worktreePath: ViewerHarness.path, acknowledging: false)
        await viewer.settle()
        #expect(viewer.controller.splitTree.allLeaves.count == 1)
        #expect(viewer.controller.selectedRemotePaneSessionName == "a")
        #expect(viewer.errors.messages.count == 1)
        #expect(viewer.model.operationTasks[0].isCancelled)
    }

    @Test func expiredDispatchCannotAbortFreshWorkOnTheSameMac() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")
        viewer.surfaces.send(.split(.right), from: a)
        await viewer.settle()
        viewer.clock.fire(.seconds(30))
        await viewer.settle()
        viewer.surfaces.send(.split(.down), from: a)
        viewer.surfaces.send(.equalize, from: a)
        await viewer.settle()
        #expect(viewer.model.requests.count == 2)
        try await viewer.answer(0, .error(code: "downstream-unavailable", message: "late failure"))
        #expect(viewer.errors.messages.count == 1)
        try await viewer.answer(1, .splitCreated(sessionName: "b"))
        #expect(viewer.model.requests.last == .equalize(target: "b"))
    }

    @Test func expiredEqualizeCannotClearRestoredZoom() async throws {
        let viewer = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let a = try viewer.terminal("a")
        viewer.surfaces.send(.toggleZoom, from: a)
        viewer.surfaces.send(.equalize, from: a)
        await viewer.settle()
        viewer.clock.fire(.seconds(30))
        await viewer.settle()
        #expect(viewer.controller.splitTree.zoomed == a)
        viewer.surfaces.send(.resize(direction: .left, amount: 3), from: a)
        await viewer.settle()
        try await viewer.answer(0, .ok)
        #expect(viewer.controller.splitTree.zoomed == a)
        #expect(viewer.model.requests.count == 2)
        #expect(viewer.errors.messages.count == 1)
    }

    @Test("@spec REMOTE-24.2: When a queued remote split completes with its created session, the viewer shall retarget later queued commands that followed the split source in the same focus generation onto the created pane.")
    func completedSplitRetargetsQueuedCommands() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")

        viewer.surfaces.send(.split(.right), from: a)
        viewer.surfaces.send(.split(.down), from: a)
        viewer.surfaces.send(.equalize, from: a)
        viewer.surfaces.send(.close, from: a)
        await viewer.settle()

        try await viewer.answer(0, .splitCreated(sessionName: "b"))
        await viewer.settle()
        #expect(viewer.model.requests.last == .split(target: "b", direction: .down))

        try await viewer.answer(1, .splitCreated(sessionName: "c"))
        await viewer.settle()
        #expect(viewer.model.requests.last == .equalize(target: "c"))

        try await viewer.answer(2, .ok)
        await viewer.settle()
        #expect(viewer.model.requests.last == .close(target: "c"))
    }

    @Test("@spec REMOTE-24.3: If the user explicitly focuses, zooms, or selects a pane while a remote split is in flight, then the viewer shall neither move focus to the pane that split creates nor retarget commands queued after that intent.")
    func explicitIntentDuringSplitKeepsFocusAndTargets() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")

        viewer.surfaces.send(.split(.right), from: a)
        await viewer.settle()
        viewer.controller.focusTerminal(a)
        viewer.surfaces.send(.equalize, from: a)

        try await viewer.answer(0, .splitCreated(sessionName: "b"))
        await viewer.settle()
        #expect(viewer.model.requests.last == .equalize(target: "a"))

        viewer.publish(.split(.leaf("a"), .leaf("b")))
        await viewer.settle()
        #expect(viewer.controller.selectedRemotePaneSessionName == "a")
        #expect(viewer.controller.focusedTerminalID == a)

        // The snapshot-first ordering is the one where a created pane would
        // otherwise take focus (REMOTE-24.12), so the suppression is only
        // observable here; response-first loses focus anyway (#586).
        let snapshotFirst = try await ViewerHarness.opened(layout: .leaf("a"))
        let first = try snapshotFirst.terminal("a")
        snapshotFirst.surfaces.send(.split(.right), from: first)
        await snapshotFirst.settle()
        snapshotFirst.controller.focusTerminal(first)
        snapshotFirst.publish(.split(.leaf("a"), .leaf("b")))
        await snapshotFirst.settle()
        try await snapshotFirst.answer(0, .splitCreated(sessionName: "b"))
        await snapshotFirst.settle()
        #expect(snapshotFirst.controller.selectedRemotePaneSessionName == "a")
        #expect(snapshotFirst.surfaces.focused == first)
    }

    @Test("@spec REMOTE-24.4: If a remote split fails with a cancelled or downstream-unavailable code, then the viewer shall drop every queued mutation for that worktree, alerting only for downstream-unavailable; for any other error the viewer shall continue with the next queued mutation and show the error unless its code is no-matching-split.")
    func failedSplitAbortsOrContinuesTheQueue() async throws {
        let cancelled = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try cancelled.terminal("a")
        cancelled.surfaces.send(.split(.right), from: a)
        cancelled.surfaces.send(.split(.down), from: a)
        cancelled.surfaces.send(.equalize, from: a)
        await cancelled.settle()
        try await cancelled.answer(0, .error(code: "cancelled", message: "cancelled"))
        await cancelled.settle()
        #expect(cancelled.model.requests.count == 1)
        #expect(cancelled.errors.messages.isEmpty)
        cancelled.surfaces.send(.split(.left), from: a)
        await cancelled.settle()
        #expect(cancelled.model.requests.last == .split(target: "a", direction: .left))

        let unreachable = try await ViewerHarness.opened(layout: .leaf("a"))
        let unreachableA = try unreachable.terminal("a")
        unreachable.surfaces.send(.split(.right), from: unreachableA)
        unreachable.surfaces.send(.split(.down), from: unreachableA)
        await unreachable.settle()
        try await unreachable.answer(0, .error(code: "downstream-unavailable", message: "offline"))
        await unreachable.settle()
        #expect(unreachable.model.requests.count == 1)
        #expect(unreachable.errors.messages == ["offline"])

        let conflict = try await ViewerHarness.opened(layout: .leaf("a"))
        let conflictA = try conflict.terminal("a")
        conflict.surfaces.send(.split(.right), from: conflictA)
        conflict.surfaces.send(.split(.down), from: conflictA)
        await conflict.settle()
        try await conflict.answer(0, .error(code: "conflict", message: "busy"))
        await conflict.settle()
        #expect(conflict.model.requests == [
            .split(target: "a", direction: .right),
            .split(target: "a", direction: .down),
        ])
        #expect(conflict.errors.messages == ["busy"])
    }

    @Test("@spec REMOTE-24.5: When a host answers a remote split with a bare ok, the viewer shall keep that split in flight until a snapshot shows a new pane and shall then send the next queued mutation; if ten seconds elapse first, the viewer shall cancel that worktree's queued mutations, report the timeout, and restore the prior zoom if its pane is present and no newer user intent superseded it.")
    func legacySplitWaitsForSnapshotOrTimeout() async throws {
        let snapshot = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try snapshot.terminal("a")
        snapshot.surfaces.send(.split(.right), from: a)
        snapshot.surfaces.send(.split(.down), from: a)
        await snapshot.settle()
        try await snapshot.answer(0, .ok)
        await snapshot.settle()
        #expect(snapshot.model.requests.count == 1)
        #expect(snapshot.clock.requested == [.seconds(30), .seconds(10)])
        snapshot.publish(.split(.leaf("a"), .leaf("b")))
        await snapshot.settle()
        #expect(snapshot.model.requests.last == .split(target: "b", direction: .down))
        snapshot.clock.fire(.seconds(10))
        await snapshot.settle()
        #expect(snapshot.errors.messages.isEmpty)
        #expect(snapshot.model.requests.count == 2)

        let timeout = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let timeoutA = try timeout.terminal("a")
        timeout.surfaces.send(.toggleZoom, from: timeoutA)
        timeout.surfaces.send(.split(.right), from: timeoutA)
        timeout.surfaces.send(.resize(direction: .left, amount: 3), from: timeoutA)
        await timeout.settle()
        try await timeout.answer(0, .ok)
        await timeout.settle()
        timeout.clock.fire(.seconds(10))
        await timeout.settle()
        // The batch is abandoned with feedback and the split's unzoom rolls
        // back. A stale deadline must not alert twice or affect fresh work.
        #expect(timeout.model.requests.count == 1)
        #expect(timeout.controller.splitTree.zoomed == timeoutA)
        #expect(timeout.errors.messages.count == 1)
        #expect(timeout.errors.messages.first?.contains("timed out") == true)
        #expect(timeout.errors.messages.first?.contains("cancelled") == true)
        timeout.clock.fire(.seconds(10))
        await timeout.settle()
        #expect(timeout.errors.messages.count == 1)
        timeout.surfaces.send(.split(.left), from: timeoutA)
        await timeout.settle()
        #expect(timeout.model.requests.last == .split(target: "a", direction: .left))
    }

    @Test(arguments: [false, true])
    func legacyTimeoutDoesNotUndoNewUserIntent(rezoom: Bool) async throws {
        let viewer = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let a = try viewer.terminal("a")
        let b = try viewer.terminal("b")
        viewer.surfaces.send(.toggleZoom, from: a)
        viewer.surfaces.send(.split(.right), from: a)
        viewer.surfaces.send(.equalize, from: a)
        await viewer.settle()
        try await viewer.answer(0, .ok)
        #expect(viewer.controller.splitTree.zoomed == nil)
        if rezoom {
            viewer.surfaces.send(.toggleZoom, from: b)
        } else {
            viewer.controller.focusTerminal(b)
        }
        viewer.clock.fire(.seconds(10))
        await viewer.settle()
        #expect(viewer.controller.splitTree.zoomed == (rezoom ? b : nil))
        #expect(viewer.errors.messages.count == 1)
        #expect(viewer.model.requests.count == 1)
    }

    @Test("@spec REMOTE-24.6: When a remote close succeeds, the viewer shall remove the closed pane from its layout and focus the projected replacement before the next snapshot arrives, and shall ignore commands from the final closed pane until a snapshot catches up.")
    func successfulCloseProjectsTheLayout() async throws {
        let viewer = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let a = try viewer.terminal("a")
        let b = try viewer.terminal("b")

        viewer.surfaces.send(.close, from: a)
        await viewer.settle()
        #expect(viewer.model.requests == [.close(target: "a")])
        try await viewer.answer(0, .ok)
        await viewer.settle()
        #expect(viewer.controller.splitTree.allLeaves == [b])
        #expect(viewer.controller.selectedRemotePaneSessionName == "b")
        #expect(viewer.surfaces.focused == b)

        viewer.publish(.leaf("b"))
        await viewer.settle()
        #expect(viewer.surfaces.destroyed.contains(a))
        #expect(viewer.controller.splitTree.allLeaves == [b])

        let last = try await ViewerHarness.opened(layout: .leaf("a"))
        let lastA = try last.terminal("a")
        last.surfaces.send(.close, from: lastA)
        await last.settle()
        try await last.answer(0, .ok)
        await last.settle()
        #expect(last.controller.splitTree.root == nil)
        last.surfaces.send(.split(.right), from: lastA)
        await last.settle()
        #expect(last.model.requests == [.close(target: "a")])
    }

    @Test("@spec REMOTE-24.7: When a remote equalize fails, the viewer shall restore the snapshot layout and the zoom it cleared; when it succeeds, the viewer shall keep the zoom cleared unless the user zoomed again after sending it.")
    func equalizeRestoresOrClearsZoom() async throws {
        let failed = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let a = try failed.terminal("a")
        failed.surfaces.send(.toggleZoom, from: a)
        #expect(failed.controller.splitTree.zoomed == a)
        failed.surfaces.send(.equalize, from: a)
        await failed.settle()
        #expect(failed.controller.splitTree.zoomed == nil)
        try await failed.answer(0, .error(code: "conflict", message: "nope"))
        await failed.settle()
        #expect(failed.controller.splitTree.zoomed == a)
        #expect(failed.errors.messages == ["nope"])

        let rezoomed = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let rezoomedB = try rezoomed.terminal("b")
        rezoomed.surfaces.send(.equalize, from: rezoomedB)
        await rezoomed.settle()
        rezoomed.surfaces.send(.toggleZoom, from: rezoomedB)
        try await rezoomed.answer(0, .ok)
        await rezoomed.settle()
        #expect(rezoomed.controller.splitTree.zoomed == rezoomedB)
    }

    @Test("@spec REMOTE-24.8: When a remote surface closes unexpectedly or fails to open, the viewer shall wait 750 ms before retrying, double successive retry delays up to thirty seconds, reset the delay after a surface survives thirty seconds, and retry only while its worktree is selected and the host still lists the pane.")
    func surfacesAreRecreatedAndRetried() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let original = try viewer.terminal("a")
        viewer.surfaces.closeUnexpectedly(original)
        await viewer.settle()
        #expect(viewer.surfaces.live.isEmpty)
        viewer.publish(.leaf("a"))
        await viewer.settle()
        #expect(viewer.surfaces.live.isEmpty)
        #expect(viewer.clock.requested == [.milliseconds(750)])
        viewer.clock.fire(.milliseconds(750))
        await viewer.settle()
        let replacement = try viewer.terminal("a")
        #expect(replacement != original)
        #expect(viewer.surfaces.destroyed.contains(original))
        #expect(viewer.controller.splitTree.allLeaves == [replacement])

        let retry = try await ViewerHarness.opened(layout: .leaf("a"), failingCreates: 1)
        #expect(retry.surfaces.live.isEmpty)
        #expect(retry.clock.requested == [.milliseconds(750)])
        retry.clock.fire(.milliseconds(750))
        await retry.settle()
        #expect(retry.surfaces.live.count == 1)
    }

    @Test func repeatedTerminalClosesBackOffAndResetAfterAStableStream() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        for delay in [750, 1_500, 3_000, 6_000, 12_000, 24_000, 30_000, 30_000] {
            let terminal = try viewer.terminal("a")
            viewer.surfaces.closeUnexpectedly(terminal)
            await viewer.settle()
            #expect(viewer.surfaces.live.isEmpty)
            #expect(viewer.clock.requested.last == .milliseconds(delay))
            viewer.publish(.leaf("a"))
            await viewer.settle()
            #expect(viewer.surfaces.live.isEmpty)
            viewer.clock.fire(.milliseconds(delay))
            await viewer.settle()
            #expect(viewer.surfaces.live.count == 1)
        }
        // Only this surviving surface may reset its failure history.
        viewer.clock.fire(.seconds(30))
        await viewer.settle()
        viewer.surfaces.closeUnexpectedly(try viewer.terminal("a"))
        await viewer.settle()
        #expect(viewer.clock.requested.last == .milliseconds(750))
        #expect(viewer.surfaces.live.isEmpty)
    }

    @Test func terminalRetryCannotOutliveSelectionOrPaneRemoval() async throws {
        let removed = try await ViewerHarness.opened(layout: .leaf("a"))
        removed.surfaces.closeUnexpectedly(try removed.terminal("a"))
        await removed.settle()
        removed.publish(nil)
        removed.clock.fire(.milliseconds(750))
        await removed.settle()
        #expect(removed.surfaces.live.isEmpty)
        #expect(removed.controller.splitTree.root == nil)

        let selected = try await ViewerHarness.opened(layout: .leaf("a"))
        selected.surfaces.closeUnexpectedly(try selected.terminal("a"))
        await selected.settle()
        selected.controller.leaveForLocalSelection()
        selected.controller.selectRemoteWorktree(selected.mac, worktreePath: ViewerHarness.path, acknowledging: false)
        await selected.settle()
        selected.surfaces.closeUnexpectedly(try selected.terminal("a"))
        await selected.settle()
        // The first selection's sleeper must not consume the new retry.
        selected.clock.fireNext(.milliseconds(750))
        await selected.settle()
        #expect(selected.surfaces.live.isEmpty)
        selected.clock.fireNext(.milliseconds(750))
        await selected.settle()
        #expect(selected.surfaces.live.count == 1)
    }

    @Test func staleTerminalOpenFailureCannotScheduleANewSelectionsRetry() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        viewer.model.holdNextTerminalOpen = true
        viewer.controller.destroyAllRemoteSurfaces()
        viewer.publish(.leaf("a"))
        try await viewer.until("terminal open is suspended") { viewer.model.heldTerminalOpen != nil }
        viewer.controller.leaveForLocalSelection()
        viewer.controller.selectRemoteWorktree(viewer.mac, worktreePath: ViewerHarness.path, acknowledging: false)
        await viewer.settle()
        #expect(viewer.surfaces.live.count == 1)
        viewer.model.heldTerminalOpen?.resume(throwing: CancellationError())
        viewer.model.heldTerminalOpen = nil
        await viewer.settle()
        #expect(viewer.clock.requested.isEmpty)
        viewer.surfaces.closeUnexpectedly(try viewer.terminal("a"))
        await viewer.settle()
        #expect(viewer.clock.requested == [.milliseconds(750)])
        #expect(viewer.surfaces.live.isEmpty)
    }

    @Test(arguments: [false, true])
    func removedPaneCannotLeaveOrphanRetryState(fireOldRetryFirst: Bool) async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")
        // Model publication can precede the view's reconcile callback.
        viewer.model.worktreePanesByRemote[viewer.identity] = []
        viewer.surfaces.closeUnexpectedly(a)
        await viewer.settle()
        if fireOldRetryFirst {
            viewer.clock.fire(.milliseconds(750))
            await viewer.settle()
        }
        viewer.publish(.leaf("a"))
        await viewer.settle()
        #expect(viewer.surfaces.live.count == 1)
        viewer.surfaces.closeUnexpectedly(try viewer.terminal("a"))
        await viewer.settle()
        #expect(viewer.surfaces.live.isEmpty)
        #expect(viewer.clock.requested.last == .milliseconds(750))
        if !fireOldRetryFirst {
            viewer.clock.fireNext(.milliseconds(750))
            await viewer.settle()
            #expect(viewer.surfaces.live.isEmpty)
        }
        viewer.clock.fire(.milliseconds(750))
        await viewer.settle()
        #expect(viewer.surfaces.live.count == 1)
    }

    @Test func failedReopenContinuesTheTerminalBackoff() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        viewer.model.failingTerminalOpens = 1
        viewer.surfaces.closeUnexpectedly(try viewer.terminal("a"))
        await viewer.settle()
        #expect(viewer.surfaces.live.isEmpty)
        viewer.clock.fire(.milliseconds(750))
        await viewer.settle()
        #expect(viewer.surfaces.live.isEmpty)
        #expect(viewer.clock.requested.last == .milliseconds(1_500))
        viewer.clock.fire(.milliseconds(1_500))
        await viewer.settle()
        #expect(viewer.surfaces.live.count == 1)
    }

    @Test("@spec REMOTE-24.9: When the window disappears, the viewer shall destroy every remote surface and empty its layout while keeping the selection, so that the next snapshot recreates the surfaces; the panes' registered command handlers shall not keep the viewer alive.")
    func disappearResetsSurfacesAndHandlersDoNotRetainTheViewer() async throws {
        let viewer = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let before = viewer.surfaces.live
        viewer.controller.destroyAllRemoteSurfaces()
        #expect(viewer.surfaces.live.isEmpty)
        #expect(viewer.controller.splitTree.root == nil)
        #expect(viewer.controller.selectedRemoteWorktreePath == ViewerHarness.path)
        viewer.publish(.split(.leaf("a"), .leaf("b")))
        await viewer.settle()
        #expect(viewer.surfaces.live.count == 2)
        #expect(viewer.surfaces.live.isDisjoint(with: before))

        let surfaces = FakeViewerSurfaces()
        weak var released: RemoteWorktreeViewerController?
        do {
            let harness = try await ViewerHarness.opened(layout: .leaf("a"), surfaces: surfaces)
            released = harness.controller
            #expect(surfaces.live.count == 1)
        }
        #expect(released == nil)
    }

    @Test("@spec REMOTE-24.10: When the viewer sends a remote resize, it shall carry the key window's content extent along the resize axis.")
    func resizeCarriesTheViewportExtent() async throws {
        let viewer = try await ViewerHarness.opened(layout: .split(.leaf("a"), .leaf("b")))
        let a = try viewer.terminal("a")
        viewer.surfaces.send(.resize(direction: .down, amount: 5), from: a)
        await viewer.settle()
        try await viewer.answer(0, .ok)
        viewer.surfaces.send(.resize(direction: .right, amount: 7), from: a)
        await viewer.settle()
        #expect(viewer.model.requests == [
            .resize(target: "a", direction: .down, amount: 5, viewportExtent: 600),
            .resize(target: "a", direction: .right, amount: 7, viewportExtent: 1000),
        ])
    }

    @Test("@spec REMOTE-24.11: When the user selects a closed remote worktree, the viewer shall ask the host to open it and show it as opening until a snapshot shows it no longer closed; if the open fails, the viewer shall show the error and stop showing it as opening.")
    func closedWorktreeOpensOnSelection() async throws {
        let opened = try await ViewerHarness.opened(layout: nil, state: .closed)
        #expect(opened.model.openedWorktrees == [ViewerHarness.path])
        #expect(opened.controller.isOpeningSelectedWorktree)
        opened.publish(.leaf("a"))
        await opened.settle()
        #expect(!opened.controller.isOpeningSelectedWorktree)
        #expect(opened.surfaces.live.count == 1)

        let failed = try await ViewerHarness.opened(
            layout: nil,
            state: .closed,
            openResponse: .error(code: "failed", message: "no such worktree", forceAllowed: false, shortStatus: nil)
        )
        #expect(!failed.controller.isOpeningSelectedWorktree)
        #expect(failed.errors.messages == ["no such worktree"])
    }

    @Test("@spec REMOTE-24.12: When a snapshot shows the pane a remote split created before the split response arrives, and no explicit intent intervened, the viewer shall focus the created pane once the response arrives.")
    func createdPaneTakesFocusWhenTheSnapshotArrivesFirst() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")
        viewer.surfaces.send(.split(.right), from: a)
        await viewer.settle()
        viewer.publish(.split(.leaf("a"), .leaf("b")))
        await viewer.settle()
        try await viewer.answer(0, .splitCreated(sessionName: "b"))
        await viewer.settle()
        let b = try viewer.terminal("b")
        #expect(viewer.controller.selectedRemotePaneSessionName == "b")
        #expect(viewer.surfaces.focused == b)
    }

    @Test("@spec REMOTE-24.13: While remote pane mutations are queued or in flight, the viewer shall publish a change only when its selection, layout, or opening state changes, so queue bookkeeping alone does not re-evaluate the window.")
    func queueBookkeepingDoesNotPublish() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")
        var published = 0
        let subscription = viewer.controller.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }
        var publishingSteps: [String] = []
        func step(_ name: String, _ body: () async throws -> Void) async throws {
            let before = published
            try await body()
            await viewer.settle()
            if published != before { publishingSteps.append(name) }
        }

        // Only the snapshots that add panes (and move focus to them) change
        // what the window draws. Sending, queueing, retargeting, and
        // answering the mutations behind them do not; the split's local
        // unzoom is a no-op on an unzoomed tree. With every queue field
        // published, as when they were MainWindow `@State`, all 8 steps
        // publish (65 sends).
        try await step("split") { viewer.surfaces.send(.split(.right), from: a) }
        try await step("queue split") { viewer.surfaces.send(.split(.down), from: a) }
        try await step("queue equalize") { viewer.surfaces.send(.equalize, from: a) }
        try await step("split 1 answered") { try await viewer.answer(0, .splitCreated(sessionName: "b")) }
        try await step("snapshot 1") { viewer.publish(.split(.leaf("a"), .leaf("b"))) }
        try await step("split 2 answered") { try await viewer.answer(1, .splitCreated(sessionName: "c")) }
        try await step("snapshot 2") { viewer.publish(.split(.leaf("a"), .split(.leaf("b"), .leaf("c")))) }
        try await step("equalize answered") { try await viewer.answer(2, .ok) }
        #expect(publishingSteps == ["snapshot 1", "snapshot 2"])
    }

    /// The response-first ordering loses focus to the source pane (#586):
    /// the snapshot's reconcile passes the pre-split selection as preferred.
    @Test func createdPaneTakesFocusWhenTheResponseArrivesFirst() async throws {
        let viewer = try await ViewerHarness.opened(layout: .leaf("a"))
        let a = try viewer.terminal("a")
        viewer.surfaces.send(.split(.right), from: a)
        await viewer.settle()
        try await viewer.answer(0, .splitCreated(sessionName: "b"))
        await viewer.settle()
        viewer.publish(.split(.leaf("a"), .leaf("b")))
        await viewer.settle()
        withKnownIssue("#586: split focus reverts when the response precedes the snapshot") {
            #expect(viewer.controller.selectedRemotePaneSessionName == "b")
        }
    }
}

// MARK: - Harness

@MainActor
private final class ViewerHarness {
    static let path = "/repo/feature"

    let mac: RemoteMac
    let identity: RemoteMacIdentity
    let model: FakeViewerModel
    let surfaces: FakeViewerSurfaces
    let clock = ManualViewerClock()
    let errors = ViewerErrorLog()
    let controller: RemoteWorktreeViewerController
    var state: WorktreeWireState

    private init(surfaces: FakeViewerSurfaces, state: WorktreeWireState) throws {
        mac = RemoteMac(
            id: RemoteDeviceID(value: "studio-mac"),
            label: "Studio Mac",
            fingerprint: try RemoteIdentityFingerprint(rawBytes: Data(repeating: 0x22, count: 32)),
            lastKnownBaseURL: URL(string: "http://studio.local:9443"),
            addedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        identity = RemoteMacIdentity(mac)
        model = FakeViewerModel(savedRemoteMacs: [mac])
        self.surfaces = surfaces
        self.state = state
        controller = RemoteWorktreeViewerController(
            model: model,
            surfaces: surfaces,
            presentError: { [errors] in errors.messages.append($0) },
            viewportBounds: { CGRect(x: 0, y: 0, width: 1000, height: 600) },
            sleep: { [clock] in await clock.sleep($0) }
        )
    }

    /// Publishes a snapshot, selects its worktree as a sidebar click would,
    /// and lets the surfaces open.
    static func opened(
        layout: Layout?,
        state: WorktreeWireState = .running,
        failingCreates: Int = 0,
        openResponse: WorktreeManagementResponse = .ok,
        surfaces: FakeViewerSurfaces? = nil
    ) async throws -> ViewerHarness {
        let surfaces = surfaces ?? FakeViewerSurfaces()
        let harness = try ViewerHarness(surfaces: surfaces, state: state)
        surfaces.failingCreates = failingCreates
        harness.model.openWorktreeResponse = openResponse
        harness.model.worktreePanesByRemote = [harness.identity: [harness.worktree(layout)]]
        harness.controller.reconcile(worktreePanesByRemote: harness.model.worktreePanesByRemote)
        harness.controller.selectRemoteWorktree(harness.mac, worktreePath: path, acknowledging: false)
        await harness.settle()
        return harness
    }

    func publish(_ layout: Layout?, state: WorktreeWireState = .running) {
        self.state = state
        model.worktreePanesByRemote = [identity: [worktree(layout)]]
        controller.reconcile(worktreePanesByRemote: model.worktreePanesByRemote)
    }

    func terminal(_ sessionName: String) throws -> PaneSlotID {
        try #require(surfaces.liveTerminal(forSession: sessionName))
    }

    /// Answers the `index`th pane-control request once the viewer has sent
    /// it, waiting on that condition (bounded) rather than on a turn count,
    /// and failing the test rather than trapping if it never arrives.
    func answer(_ index: Int, _ response: PaneControlResponse) async throws {
        try await until("pane-control request \(index) is sent") {
            model.paneControls.indices.contains(index)
        }
        model.paneControls[index].resolve(response)
        await settle()
    }

    /// Yields until `condition` holds; bounded, with no wall-clock waits.
    func until(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() {
            await Task.yield()
            surfaces.drainFirstResponders()
        }
        try #require(condition(), "timed out waiting until \(description); sent \(model.requests)")
    }

    /// Yields until the fakes have seen no new activity for 20 consecutive
    /// turns, so queued main-actor tasks and deferred first-responder
    /// promotions have run. Bounded, with no wall-clock waits; a viewer
    /// that keeps working past the bound is a test failure.
    ///
    /// Every task involved (the controller's, the fake pane-control and
    /// open tasks) is main-actor isolated, so a resumed continuation is
    /// enqueued on the main executor ahead of this loop's next turn; the
    /// longest chain (response, handler, dispatch, surface open) is a few
    /// hops, well inside 20 quiet turns. Positive waits on a request use
    /// `until` instead.
    func settle() async {
        var quietTurns = 0
        for _ in 0..<2_000 {
            let before = activity
            await Task.yield()
            surfaces.drainFirstResponders()
            quietTurns = activity == before ? quietTurns + 1 : 0
            if quietTurns >= 20 { return }
        }
        Issue.record("viewer did not settle within 2,000 turns")
    }

    private var activity: Int {
        model.paneControls.count + model.openedWorktrees.count + surfaces.events
            + clock.requested.count + errors.messages.count
    }

    private func worktree(_ layout: Layout?) -> WorktreePanes {
        WorktreePanes(
            path: Self.path,
            displayName: "feature",
            repoDisplayName: "graftty",
            displayBranch: "feature",
            state: state,
            isMainCheckout: false,
            prBadge: nil,
            stats: nil,
            attentionText: nil,
            layout: layout?.node
        )
    }
}

private indirect enum Layout {
    case leaf(String)
    case split(Layout, Layout)

    var node: PaneLayoutNode {
        switch self {
        case .leaf(let name):
            .leaf(sessionName: name, title: name, attentionText: nil, isBusy: false, attentionSource: nil)
        case let .split(left, right):
            .split(direction: .horizontal, ratio: 0.5, left: left.node, right: right.node)
        }
    }
}

@MainActor
private final class ViewerErrorLog {
    var messages: [String] = []
}

@MainActor
private final class ManualViewerClock {
    private(set) var requested: [Duration] = []
    private var sleepers: [(Duration, CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { sleepers.append((duration, $0)) }
    }

    func fireNext(_ duration: Duration) {
        guard let index = sleepers.firstIndex(where: { $0.0 == duration }) else { return }
        sleepers.remove(at: index).1.resume()
    }

    func fire(_ duration: Duration) {
        let due = sleepers.filter { $0.0 == duration }
        sleepers.removeAll { $0.0 == duration }
        due.forEach { $0.1.resume() }
    }
}

@MainActor
private final class FakePaneControl {
    let request: PaneControlRequest
    private var resolved: PaneControlResponse?
    private var continuation: CheckedContinuation<PaneControlResponse, Never>?

    init(request: PaneControlRequest) {
        self.request = request
    }

    func response() async -> PaneControlResponse {
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ response: PaneControlResponse) {
        resolved = response
        continuation?.resume(returning: response)
        continuation = nil
    }
}

@MainActor
private final class FakeViewerModel: RemoteWorktreeViewerModel {
    var savedRemoteMacs: [RemoteMac]
    var worktreePanesByRemote: [RemoteMacIdentity: [WorktreePanes]] = [:]
    var openWorktreeResponse: WorktreeManagementResponse = .ok
    var failingTerminalOpens = 0
    var holdNextTerminalOpen = false
    var heldTerminalOpen: CheckedContinuation<Void, Error>?
    private(set) var paneControls: [FakePaneControl] = []
    private(set) var operationTasks: [Task<PaneControlResponse, Never>] = []
    private(set) var openedWorktrees: [String] = []

    var requests: [PaneControlRequest] { paneControls.map(\.request) }

    init(savedRemoteMacs: [RemoteMac]) {
        self.savedRemoteMacs = savedRemoteMacs
    }

    func queuePaneControl(on remoteMac: RemoteMac, request: PaneControlRequest) -> Task<PaneControlResponse, Never> {
        let operation = FakePaneControl(request: request)
        paneControls.append(operation)
        let task = Task { await operation.response() }
        operationTasks.append(task)
        return task
    }

    func connectViewer(to remoteMac: RemoteMac) async throws {}

    func openViewerTerminalSession(identity: RemoteMacIdentity, sessionName: String) async throws
        -> any WebSocketClient & Sendable {
        if holdNextTerminalOpen {
            holdNextTerminalOpen = false
            try await withCheckedThrowingContinuation { continuation in
                heldTerminalOpen = continuation
            }
        }
        if failingTerminalOpens > 0 {
            failingTerminalOpens -= 1
            throw CancellationError()
        }
        return FakeViewerTerminalClient(sessionName: sessionName)
    }

    func openWorktree(on remoteMac: RemoteMac, worktreePath: String) async -> WorktreeManagementResponse {
        openedWorktrees.append(worktreePath)
        return openWorktreeResponse
    }

    func acknowledgeViewedAttention(on remoteMac: RemoteMac, worktreePath: String, paneSessionName: String?) async {}

    func sendWorktreeManagement(identity: RemoteMacIdentity, request: WorktreeManagementRequest) async throws
        -> WorktreeManagementResponse {
        .ok
    }
}

private final class FakeViewerTerminalClient: WebSocketClient, @unchecked Sendable {
    let sessionName: String

    init(sessionName: String) {
        self.sessionName = sessionName
    }

    func send(_ frame: WebSocketFrame) async throws {}
    func receive() async throws -> WebSocketFrame { throw CancellationError() }
    func close() {}
}

@MainActor
private final class FakeViewerSurfaces: RemoteWorktreeViewerSurfaces {
    var splitPreserveZoomOnNavigation = false
    var failingCreates = 0
    /// Every call the viewer makes, for `settle()`'s quiescence check.
    private(set) var events = 0
    private(set) var live: Set<PaneSlotID> = []
    private(set) var destroyed: [PaneSlotID] = []
    private(set) var focused: PaneSlotID?
    private var sessionBySurface: [PaneSlotID: String] = [:]
    private var handlers: [PaneSlotID: (HostManagedPaneCommand) -> Void] = [:]
    private var unexpectedCloses: [PaneSlotID: () -> Void] = [:]
    private var pendingFirstResponders: [() -> Void] = []

    func liveTerminal(forSession sessionName: String) -> PaneSlotID? {
        live.first { sessionBySurface[$0] == sessionName }
    }

    func send(_ command: HostManagedPaneCommand, from terminalID: PaneSlotID) {
        handlers[terminalID]?(command)
    }

    func closeUnexpectedly(_ terminalID: PaneSlotID) {
        unexpectedCloses[terminalID]?()
    }

    func drainFirstResponders() {
        let pending = pendingFirstResponders
        pendingFirstResponders.removeAll()
        pending.forEach { $0() }
    }

    func hasRemoteSurface(_ terminalID: PaneSlotID) -> Bool {
        live.contains(terminalID)
    }

    func createRemoteSurface(
        terminalID: PaneSlotID,
        worktreePath: String,
        client: any WebSocketClient & Sendable,
        onUnexpectedClose: @escaping () -> Void,
        agentCompletions: @escaping () async throws -> [AgentCompletionCandidate]
    ) -> Bool {
        events += 1
        guard failingCreates == 0 else {
            failingCreates -= 1
            return false
        }
        live.insert(terminalID)
        sessionBySurface[terminalID] = (client as? FakeViewerTerminalClient)?.sessionName
        unexpectedCloses[terminalID] = onUnexpectedClose
        return true
    }

    func destroySurface(terminalID: PaneSlotID) {
        events += 1
        if live.remove(terminalID) != nil { destroyed.append(terminalID) }
        handlers[terminalID] = nil
        unexpectedCloses[terminalID] = nil
        if focused == terminalID { focused = nil }
    }

    func setVisible(_ visible: Bool, for terminalID: PaneSlotID) {
        events += 1
    }

    func setFocus(_ terminalID: PaneSlotID) {
        events += 1
        focused = terminalID
    }

    func registerHostManagedPaneCommandHandler(
        for terminalID: PaneSlotID,
        handler: @escaping (HostManagedPaneCommand) -> Void
    ) {
        events += 1
        handlers[terminalID] = handler
    }

    func promoteToFirstResponder(
        _ terminalID: PaneSlotID,
        when shouldFocus: (() -> Bool)?,
        onFocused: (() -> Void)?
    ) {
        events += 1
        pendingFirstResponders.append {
            if shouldFocus?() ?? true { onFocused?() }
        }
    }
}
