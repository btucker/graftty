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
        var cards = state.rows.compactMap { row in
            hosts.first(where: { $0.id == state.hostID(for: row) }).flatMap { card(row, host: $0) }
        }
        let liveIDs = Set(cards.map(\.id))
        cards += previous.cards.filter { unavailableIDs.contains($0.hostID) && !liveIDs.contains($0.id) }
        var terminals = state.rows.flatMap { row in
            hosts.first(where: { $0.id == state.hostID(for: row) }).map { terminalTargets(row, host: $0) } ?? []
        }
        let liveTerminalIDs = Set(terminals.map(\.id))
        terminals += (previous.terminals ?? []).filter { unavailableIDs.contains($0.hostID) && !liveTerminalIDs.contains($0.id) }
        cards.sort { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        return .init(cards: cards, updatedAt: .now, unavailableHosts: unavailable.map(\.label),
                     omittedCount: unavailableIDs.isEmpty ? 0 : previous.omittedCount, terminals: terminals,
                     omittedTerminalCount: unavailableIDs.isEmpty ? 0 : previous.omittedTerminalCount ?? 0)
    }

    static func card(_ row: WorktreePanes, host: Host) -> WatchAttentionCard? {
        guard row.state.hasOnDiskWorktree else { return nil }
        let context = SidebarWorktreeContext(worktree: row)
        // Include non-question attention too, but never turn an arbitrary terminal
        // prompt into a text-answer target.
        guard let pending = context.questionItem ?? context.pending.first else { return nil }
        let question = context.question ?? pending.occurrence?.text ?? pending.title
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
            resourceID: "\(row.origin?.deviceID.value ?? host.remoteDeviceID?.value ?? host.id.uuidString)\u{0}\(row.sidebar?.id ?? row.path)")
        let terminals = terminalTargets(row, host: host)
        let pane = context.questionPaneID ?? pending.paneID ?? context.agentPaneID
        card.terminal = terminals.first { $0.paneID == pane } ?? (terminals.count == 1 ? terminals.first : nil)
        return card
    }

    static func terminalTargets(_ row: WorktreePanes, host: Host) -> [WatchTerminalTarget] {
        guard row.state == .running else { return [] }
        return (row.layout?.leaves ?? []).map { pane in
            .init(hostID: host.id, worktreeID: row.path, paneID: pane.sessionName,
                  project: row.repoDisplayName, worktree: row.displayName, host: row.origin?.deviceLabel ?? host.label,
                  title: pane.title.isEmpty ? row.displayName : pane.title,
                  resourceID: "\(row.origin?.deviceID.value ?? host.remoteDeviceID?.value ?? host.id.uuidString)\u{0}\(row.sidebar?.id ?? row.path)\u{0}\(row.sidebar?.paneIDs?[pane.sessionName] ?? pane.sessionName)")
        }
    }

    static func terminalRequest(_ target: WatchTerminalTarget, rows: [WorktreePanes], host: Host) throws -> WorktreeManagementRequest {
        guard target.hostID == host.id, let row = rows.first(where: { $0.path == target.worktreeID }),
              terminalTargets(row, host: host).contains(where: { $0.paneID == target.paneID }) else { throw Failure.changed }
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
