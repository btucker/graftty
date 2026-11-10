import AppKit
import CoreGraphics
import Foundation
import Testing
import CoreTransferable
import UniformTypeIdentifiers
@testable import Graftty
import GrafttyKit

@Suite("Worktree drop reorder tests")
struct WorktreeDropReorderTests {
    @Test("@spec LAYOUT-2.66: When the macOS application is bundled, the application shall export its local worktree, remote worktree, and pane drag types as data so the system can recognize sidebar drag sessions.")
    func bundledAppDeclaresSidebarDragTypes() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "cat > \"$APP/Contents/Info.plist\" <<PLIST\n")?.upperBound)
        let end = try #require(script.range(of: "\nPLIST", range: start..<script.endIndex)?.lowerBound)
        let plist = try #require(PropertyListSerialization.propertyList(from: Data(script[start..<end].utf8), format: nil) as? [String: Any])
        let declarations = try #require(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        for type in [TransferableWorktreeMove.contentType, RemoteWorktreeDragPayload.contentType] {
            let declaration = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == type.identifier })
            #expect((declaration["UTTypeConformsTo"] as? [String])?.contains(UTType.data.identifier) == true)
        }
    }

    @Test("@spec LAYOUT-2.101: When a user drops a worktree onto another worktree's block, the application shall place it before that whole worktree from the block's upper half and after it from the lower half, never between its pane rows.")
    func rowDropLocationMapsToPlacement() {
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 18), rowHeight: 44) == .before)
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 24), rowHeight: 44) == .after)
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 10), rowHeight: 24) == .before)
        #expect(WorktreeDropPlacement.fromRowDropLocation(CGPoint(x: 0, y: 14), rowHeight: 24) == .after)
    }

    @Test("Dropping a worktree on a sibling moves it to the sibling's current index")
    func droppingWorktreeOnSiblingMovesToTargetIndex() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            pinnedRow("/repo/.worktrees/a", "a"),
            pinnedRow("/repo/.worktrees/b", "b"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[2].id),
            targetWorktreeID: repo.worktrees[1].id,
            placement: .before,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "b", "a"])
    }

    @Test("Dropping a worktree after a lower sibling moves it downward")
    func droppingWorktreeAfterLowerSiblingMovesDownward() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            pinnedRow("/repo/.worktrees/a", "a"),
            pinnedRow("/repo/.worktrees/b", "b"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .after,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "b", "a"])
    }

    @Test("@spec LAYOUT-2.34: When a user drops a pinned agent onto any other pinned agent in its repository, the application shall reorder the one flat list of pinned agents, whatever their names.")
    func pinnedDropsIgnoreFolderLikeNames() {
        let lead = pinnedRow("/repo/.worktrees/research/lead", "research/lead")
        let notes = pinnedRow("/repo/.worktrees/research/notes", "research/notes")
        let solo = pinnedRow("/repo/.worktrees/solo", "solo")
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [lead, notes, solo])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: lead.id),
            targetWorktreeID: solo.id,
            placement: .after,
            to: &state
        )

        #expect(changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["research/notes", "solo", "research/lead"])
    }

    @Test("Drops from another repo are ignored")
    func crossRepoDropIsIgnored() {
        let first = RepoEntry(path: "/repo-a", displayName: "repo-a", worktrees: [
            WorktreeEntry(path: "/repo-a", branch: "main"),
        ])
        let second = RepoEntry(path: "/repo-b", displayName: "repo-b", worktrees: [
            WorktreeEntry(path: "/repo-b", branch: "main"),
            WorktreeEntry(path: "/repo-b/.worktrees/feature", branch: "feature"),
        ])
        var state = AppState(repos: [first, second])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: second.id, worktreeID: second.worktrees[1].id),
            targetWorktreeID: first.worktrees[0].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main"])
        #expect(state.repos[1].worktrees.map(\.branch) == ["main", "feature"])
    }

    @Test("In-flight source and target worktrees are ignored")
    func inFlightSourceAndTargetDropsAreIgnored() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/creating", branch: "creating", state: .creating),
            WorktreeEntry(path: "/repo/.worktrees/deleting", branch: "deleting", state: .deleting),
            WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature"),
        ])
        var sourceState = AppState(repos: [repo])
        var targetState = AppState(repos: [repo])

        let sourceChanged = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[0].id,
            placement: .before,
            to: &sourceState
        )
        let targetChanged = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[3].id),
            targetWorktreeID: repo.worktrees[2].id,
            placement: .before,
            to: &targetState
        )

        #expect(!sourceChanged)
        #expect(!targetChanged)
        #expect(sourceState.repos[0].worktrees.map(\.branch) == ["main", "creating", "deleting", "feature"])
        #expect(targetState.repos[0].worktrees.map(\.branch) == ["main", "creating", "deleting", "feature"])
    }

    @Test("Custom drops reject in-flight destination neighbors")
    func customDropsRejectInFlightDestinationNeighbors() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/moving", branch: "moving"),
            WorktreeEntry(path: "/repo/.worktrees/creating", branch: "creating", state: .creating),
            WorktreeEntry(path: "/repo/.worktrees/feature", branch: "feature"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[3].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "moving", "creating", "feature"])
    }

    @Test("Dropping a worktree on itself is ignored")
    func selfDropIsIgnored() {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/a", branch: "a"),
        ])
        var state = AppState(repos: [repo])

        let changed = WorktreeDropReorder.apply(
            TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id),
            targetWorktreeID: repo.worktrees[1].id,
            placement: .before,
            to: &state
        )

        #expect(!changed)
        #expect(state.repos[0].worktrees.map(\.branch) == ["main", "a"])
    }
}

@Suite("AppKit worktree drag source")
struct WorktreeDragSourceTests {
    @Test("@spec LAYOUT-2.100: When a user drags a worktree heading, the application shall begin an AppKit drag session that lifts the whole worktree block and whose pasteboard payload the worktree row drop destination decodes as that worktree move.")
    func pasteboardPayloadRoundTripsThroughRowDrop() async throws {
        let repo = RepoEntry(path: "/repo", displayName: "repo", worktrees: [
            WorktreeEntry(path: "/repo", branch: "main"),
            WorktreeEntry(path: "/repo/.worktrees/a", branch: "a"),
        ])
        let payload = TransferableWorktreeMove(repoID: repo.id, worktreeID: repo.worktrees[1].id)
        let writer = try #require(WorktreeDragPasteboardWriter(payload))
        #expect(writer.writableTypes(for: .general) == [NSPasteboard.PasteboardType(TransferableWorktreeMove.contentType.identifier)])
        let data = try #require(writer.pasteboardPropertyList(forType: WorktreeDragPasteboardWriter.pasteboardType) as? Data)
        #expect(writer.pasteboardPropertyList(forType: .string) == nil)

        // The drop side sees pasteboard items as item providers with raw data for the type.
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: TransferableWorktreeMove.contentType.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        let drop: WorktreeRowDrop = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadTransferable(type: WorktreeRowDrop.self) { continuation.resume(with: $0) }
        }
        guard case .worktree(let decoded) = drop else { Issue.record("expected worktree payload"); return }
        #expect(decoded.repoID == payload.repoID && decoded.worktreeID == payload.worktreeID)
    }

    @Test("Drag source view takes plain left presses only")
    @MainActor func hitTestGating() {
        let view = WorktreeDragSourceView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        #expect(view.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .withinApplication) == .move)
        #expect(view.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .outsideApplication) == [])
    }
}

/// Only pinned rows have a manual order.
private func pinnedRow(_ path: String, _ branch: String) -> WorktreeEntry {
    var row = WorktreeEntry(path: path, branch: branch)
    row.isPinned = true
    return row
}
