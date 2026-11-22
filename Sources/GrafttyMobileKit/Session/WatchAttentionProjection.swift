#if canImport(UIKit)
import Foundation
import GrafttyCommandUI
import GrafttyProtocol
import GrafttyRemoteClient
import GrafttyWatchKit

enum WatchAttentionProjection {
    enum Failure: LocalizedError {
        case changed
        var errorDescription: String? { "This question has changed or cleared. Refresh your watch." }
    }

    static func snapshot(from state: MultiHostFeedState, hosts: [Host], previous: WatchAttentionSnapshot) -> WatchAttentionSnapshot {
        let unavailable = hosts.filter { !state.isLive($0.id) }
        let unavailableIDs = Set(unavailable.map(\.id))
        let hostsByID = Dictionary(hosts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var liveWorktrees = Set<String>()
        var cards: [WatchAttentionCard] = []
        var terminals: [WatchTerminalTarget] = []
        for row in state.rows {
            guard let hostID = state.hostID(for: row), let host = hostsByID[hostID] else { continue }
            if state.isLive(hostID) { liveWorktrees.insert(MergedWorktreeList.identity(row)) }
            let panes = terminalTargets(row, host: host)
            terminals += panes
            if let card = card(row, host: host, terminals: panes) { cards.append(card) }
        }
        // A current row supersedes the entire cached worktree, including a
        // resolved question or a pane that disappeared on another route.
        let visibleCards = Set(cards.map(\.id))
        cards += previous.cards.filter {
            unavailableIDs.contains($0.hostID) && !liveWorktrees.contains($0.id) && !visibleCards.contains($0.id)
        }
        let visibleTerminals = Set(terminals.map(\.id))
        terminals += (previous.terminals ?? []).filter { target in
            guard unavailableIDs.contains(target.hostID), !visibleTerminals.contains(target.id) else { return false }
            guard let id = target.resourceID, let separator = id.lastIndex(of: "\u{0}") else { return true }
            return !liveWorktrees.contains(String(id[..<separator]))
        }
        cards.sort { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        return .init(cards: cards, updatedAt: .now, unavailableHosts: unavailable.map(\.label),
                     omittedCount: unavailableIDs.isEmpty ? 0 : previous.omittedCount, terminals: terminals,
                     omittedTerminalCount: unavailableIDs.isEmpty ? 0 : previous.omittedTerminalCount ?? 0)
    }

    private static func worktreeID(_ row: WorktreePanes, host: Host) -> String {
        if row.origin != nil { return MergedWorktreeList.identity(row) }
        return "\(host.remoteDeviceID?.value ?? host.id.uuidString)\u{0}\(row.sidebar?.id ?? row.path)"
    }

    static func card(_ row: WorktreePanes, host: Host) -> WatchAttentionCard? {
        card(row, host: host, terminals: terminalTargets(row, host: host))
    }

    private static func card(_ row: WorktreePanes, host: Host, terminals: [WatchTerminalTarget]) -> WatchAttentionCard? {
        guard row.state.hasOnDiskWorktree else { return nil }
        let context = SidebarWorktreeContext(worktree: row)
        // Include non-question attention too, but never turn an arbitrary terminal
        // prompt into a text-answer target.
        guard let pending = context.questionItem ?? context.pending.first else { return nil }
        let notice = pending.agentStop?.notice
        let question = context.question ?? notice ?? pending.occurrence?.text ?? pending.title
        var target: WatchAttentionCard.Target?
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if context.questionIsStoppedTurn, let pane = context.questionPaneID,
           let occurrence = context.questionOccurrence, let bytes = try? encoder.encode(occurrence) {
            target = .init(paneID: pane, occurrence: bytes)
        }
        var card = WatchAttentionCard(hostID: host.id, worktreeID: row.path, project: row.repoDisplayName,
            worktree: row.displayName, host: row.origin?.deviceLabel ?? host.label,
            title: context.brief?.title ?? row.displayName, question: question,
            context: context.questionCatchUp ?? context.brief?.completed,
            options: context.questionOptions.map { .init(label: $0.label, cost: $0.cost, suggested: $0.suggested == true) },
            target: target, timestamp: pending.occurrence?.timestamp,
            resourceID: worktreeID(row, host: host))
        card.isNotice = notice == nil ? nil : true
        let pane = SidebarProjection.attentionPaneRoute(for: pending, in: row)
        card.terminal = terminals.first { $0.paneID == pane }
        return card
    }

    static func terminalTargets(_ row: WorktreePanes, host: Host) -> [WatchTerminalTarget] {
        guard row.state == .running else { return [] }
        return (row.layout?.leaves ?? []).map { pane in
            .init(hostID: host.id, worktreeID: row.path, paneID: pane.sessionName,
                  project: row.repoDisplayName, worktree: row.displayName, host: row.origin?.deviceLabel ?? host.label,
                  title: pane.title.isEmpty ? row.displayName : pane.title,
                  resourceID: "\(worktreeID(row, host: host))\u{0}\(row.sidebar?.paneIDs?[pane.sessionName] ?? pane.sessionName)")
        }
    }

    static func terminalRequest(_ target: WatchTerminalTarget, rows: [WorktreePanes], host: Host) throws -> WorktreeManagementRequest {
        guard target.hostID == host.id, let row = rows.first(where: { $0.path == target.worktreeID }),
              terminalTargets(row, host: host).contains(where: { $0.paneID == target.paneID && $0.id == target.id })
        else { throw Failure.changed }
        return .terminalText(worktreeID: target.worktreeID, paneID: target.paneID, lines: 200)
    }

    static func answer(_ card: WatchAttentionCard, text: String, rows: [WorktreePanes], host: Host) throws -> WorktreeManagementRequest {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.id == card.hostID, !text.isEmpty, text.utf8.count <= 8_000,
              let row = rows.first(where: { $0.path == card.worktreeID }),
              let fresh = self.card(row, host: host), fresh.questionID == card.questionID,
              let target = fresh.target, target == card.target,
              let occurrence = try? JSONDecoder().decode(SidebarAttentionOccurrence.self, from: target.occurrence)
        else { throw Failure.changed }
        return .answerRequest(worktreeID: row.path, paneID: target.paneID, occurrence: occurrence, text: text)
    }
}
#endif
