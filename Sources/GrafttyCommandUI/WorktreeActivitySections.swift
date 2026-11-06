import Foundation
import GrafttyProtocol

/// A project's rows, grouped by what they want from the person looking at them.
/// `Hold` keeps rows where they are while the person is reaching for one.
public struct WorktreeActivitySections: Sendable, Equatable {
    public var needsYou: [MergedWorktreeRow] = []
    public var pinned: [MergedWorktreeNode] = []
    public var working: [MergedWorktreeRow] = []
    public var recent: [MergedWorktreeRow] = []

    /// The part of these sections a pane of the sidebar shows.
    public func placed(in section: SidebarWorktreeSection) -> WorktreeActivitySections {
        var result = self
        if section == .pinned { result.working = []; result.recent = [] }
        if section == .tasks { result.needsYou = []; result.pinned = [] }
        return result
    }

    public struct Hold: Sendable, Equatable {
        fileprivate var placements: [String: Placement] = [:]
        fileprivate var positions: [String: Int] = [:]
    }

    fileprivate enum Placement: Sendable, Equatable { case needsYou, pinned, working, recent }

    public var hold: Hold {
        var hold = Hold()
        func record(_ ids: [String], as placement: Placement) {
            for id in ids {
                hold.positions[id] = hold.positions.count
                hold.placements[id] = placement
            }
        }
        record(needsYou.map(\.id), as: .needsYou)
        record(pinned.flattenedRows.map(\.id), as: .pinned)
        record(working.map(\.id), as: .working)
        record(recent.map(\.id), as: .recent)
        return hold
    }

    /// `temporary` arrives newest first. A pin change made while held still applies:
    /// a row can only sit in Pinned if it's pinned.
    public static func make(pinned: [MergedWorktreeNode], temporary: [MergedWorktreeRow],
                            context: (WorktreePanes) -> SidebarWorktreeContext, holding hold: Hold?) -> WorktreeActivitySections {
        var result = WorktreeActivitySections()
        var pulled: Set<String> = []
        var asked: [String: Double] = [:]
        // A sleeping host's status never says working, so only creation has to ask.
        func livePlacement(_ row: MergedWorktreeRow) -> Placement {
            let rowContext = context(row.row)
            let isAsleep = row.availability == .asleep
            switch SidebarRowStatus.resolve(context: rowContext, worktree: row.row, isAsleep: isAsleep) {
            case .question, .notification:
                asked[row.id] = rowDate(row.row, context: rowContext)?.timeIntervalSinceReferenceDate ?? -.infinity
                return .needsYou
            case .working: return .working
            case .whereWeAre, .none: return row.row.state == .creating && !isAsleep ? .working : .recent
            }
        }
        for row in pinned.flattenedRows {
            let held = hold?.placements[row.id]
            if held == .needsYou || (held != .pinned && livePlacement(row) == .needsYou) {
                result.needsYou.append(row)
                pulled.insert(row.id)
            }
        }
        result.pinned = pruned(pinned, removing: pulled)
        for row in temporary {
            // A pin change applies even while held: see above.
            let held = hold?.placements[row.id].flatMap { $0 == .pinned ? nil : $0 }
            switch held ?? livePlacement(row) {
            case .needsYou: result.needsYou.append(row)
            case .working: result.working.append(row)
            case .recent, .pinned: result.recent.append(row)
            }
        }
        if let hold {
            func heldOrder(_ rows: [MergedWorktreeRow]) -> [MergedWorktreeRow] {
                rows.enumerated().sorted {
                    let left = hold.positions[$0.element.id] ?? hold.positions.count + $0.offset
                    let right = hold.positions[$1.element.id] ?? hold.positions.count + $1.offset
                    return left < right
                }.map(\.element)
            }
            result.needsYou = heldOrder(result.needsYou)
            result.working = heldOrder(result.working)
            result.recent = heldOrder(result.recent)
        } else {
            result.needsYou = result.needsYou.enumerated().sorted {
                let left = asked[$0.element.id] ?? -.infinity, right = asked[$1.element.id] ?? -.infinity
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
        }
        return result
    }

    /// A long Needs you list mustn't push the project list off the first screen.
    public static func preview(_ rows: [MergedWorktreeRow], showsAll: Bool, limit: Int = 2) -> (rows: [MergedWorktreeRow], hidden: Int) {
        showsAll ? (rows, 0) : (Array(rows.prefix(limit)), max(0, rows.count - limit))
    }

    private static func pruned(_ nodes: [MergedWorktreeNode], removing ids: Set<String>) -> [MergedWorktreeNode] {
        nodes.compactMap { node in
            switch node {
            case .row(let row): return ids.contains(row.id) ? nil : node
            case .folder(let id, let name, let children):
                let kept = pruned(children, removing: ids)
                return kept.isEmpty ? nil : .folder(id: id, name: name, children: kept)
            }
        }
    }

    /// What a row's time means: when it asked, or else when it was last active.
    public static func rowDate(_ worktree: WorktreePanes, context: SidebarWorktreeContext) -> Date? {
        context.pending.compactMap { $0.occurrence?.timestamp }.max()
            ?? worktree.sidebar?.activityTime.map(Date.init(timeIntervalSinceReferenceDate:))
    }

    /// The date comes off the wire, and converting a huge one to `Int` would trap.
    public static func ageText(since date: Date, now: Date) -> String {
        let minutes = Int(max(0, min(now.timeIntervalSince(date) / 60, Double(Int32.max))))
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        if minutes < 60 * 24 * 7 { return "\(minutes / (60 * 24))d" }
        return "\(minutes / (60 * 24 * 7))w"
    }
}
