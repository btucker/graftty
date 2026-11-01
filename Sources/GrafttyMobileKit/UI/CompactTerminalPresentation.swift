import Foundation
import GrafttyProtocol
import Observation

/// The sheet owns shell selection; the underlying agent route stays mounted.
@MainActor
@Observable
final class CompactTerminalPresentation {
    var isPresented = false
    private(set) var selectedSession: String?
    private(set) var isCreating = false
    private(set) var error: String?
    private var awaitingInventory: String?
    private(set) var pendingUntil: Date?
    private var previousSessions: Set<String> = []
    private var latestSessions: [String] = []

    static func terminals(in worktree: WorktreePanes) -> [PaneLayoutNode.Leaf] {
        let agents = Set(worktree.agents?.compactMap(\.presentationSessionName) ?? [])
        return worktree.layout?.leaves.filter { !agents.contains($0.sessionName) } ?? []
    }

    /// @spec IPAD-2.25
    /// Hosts send an agents list for every worktree, often empty. Only a
    /// worktree with an agent the phone can show uses the agent workspace.
    static func agentWorkspace(path: String?, rows: [WorktreePanes], fallback: WorktreePanes?) -> WorktreePanes? {
        guard let row = rows.first(where: { $0.path == path }) ?? fallback.flatMap({ $0.path == path ? $0 : nil }),
              row.agents?.contains(where: { $0.presentationSessionName != nil }) == true else { return nil }
        return row
    }

    func open(in worktree: WorktreePanes, create: () async throws -> String?) async {
        isPresented = true
        guard !isCreating else { return }
        reconcile(in: worktree)
        if selectedSession == nil && pendingUntil == nil && error == nil {
            previousSessions = Set(Self.terminals(in: worktree).map(\.sessionName))
            await newTerminal(create: create)
        }
    }

    func select(_ session: String, in worktree: WorktreePanes) {
        guard Self.terminals(in: worktree).contains(where: { $0.sessionName == session }) else { return }
        selectedSession = session
        awaitingInventory = nil
        pendingUntil = nil
    }

    func reconcile(in worktree: WorktreePanes, now: Date = Date()) {
        latestSessions = Self.terminals(in: worktree).map(\.sessionName)
        guard !isCreating else { return }
        reconcileInventory(now: now)
    }

    private func reconcileInventory(now: Date) {
        let sessions = latestSessions
        if let pendingUntil {
            let found = awaitingInventory.flatMap { sessions.contains($0) ? $0 : nil }
                ?? (awaitingInventory == nil ? sessions.first { !previousSessions.contains($0) } : nil)
            if let found {
                selectedSession = found
                self.pendingUntil = nil
                awaitingInventory = nil
            } else if now < pendingUntil {
                return
            } else {
                self.pendingUntil = nil
                awaitingInventory = nil
                error = "The host has not reported the new terminal. Check the connection before creating another."
            }
        }
        if !sessions.contains(selectedSession ?? "") { selectedSession = sessions.first }
        previousSessions = Set(sessions)
    }

    func expirePendingCreation(now: Date = Date()) {
        guard pendingUntil != nil, !isCreating else { return }
        reconcileInventory(now: now)
    }

    func newTerminal(create: () async throws -> String?) async {
        guard !isCreating, pendingUntil == nil else { return }
        isCreating = true
        previousSessions = Set(latestSessions)
        error = nil
        defer { isCreating = false }
        do {
            let session = try await create()
            selectedSession = session
            awaitingInventory = session
            pendingUntil = Date().addingTimeInterval(5)
            reconcileInventory(now: Date())
        } catch {
            self.error = error.localizedDescription
        }
    }
}
