import GrafttyProtocol
import SwiftUI

/// The history stays open; peer runs become sender cards and older runs of agent work can fold.
struct WorktreeHistoryContent: View {
    let timeline: WorktreeTimeline
    let secondary: Color
    var openWorktree: ((String) -> Bool)? = nil
    var gists: PeerMessageGistProvider = .shared
    @State private var showsAll = false
    @State private var expandedGroups: Set<String> = []
    @State private var unavailableWorktree = false

    var body: some View {
        let focused = timeline.rows(showAll: false)
        let hasGroups = focused.contains(where: \.isGroup)
        let rows = showsAll ? timeline.rows(showAll: true) : focused
        let days = Self.dayLabels(rows)
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("How we got here").font(.callout).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text("Oldest first ↓").font(.caption2).foregroundStyle(secondary)
            }
            .accessibilityIdentifier("worktree.context.history")
            if hasGroups {
                Button(showsAll ? "Show highlights" : "Show all \(timeline.events.count) steps") {
                    showsAll.toggle()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .frame(minHeight: 32, alignment: .leading)
                .accessibilityIdentifier("worktree.context.history.all")
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if let day = days[index] {
                        Text(day).font(.caption).fontWeight(.medium).foregroundStyle(secondary)
                            .padding(.bottom, 10)
                            .accessibilityAddTraits(.isHeader)
                    }
                    switch row.kind {
                    case .folded: group(row)
                    case .event: eventRow(row.events[0])
                    case .inputs: railed(row.events) { inputs(row) }
                    case .peerMessages: railed(row.events) { peerCard(row) }
                    }
                }
            }
        }
        .alert("Worktree unavailable", isPresented: $unavailableWorktree) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This worktree is no longer available on the connected host.")
        }
    }

    private func group(_ row: WorktreeTimeline.Row) -> some View {
        let range = groupDateRange(row)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggle(row.id)
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: expandedGroups.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2).frame(width: 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.events.count) agent steps").font(.caption)
                        Text(range).font(.caption2).foregroundStyle(secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityLabel("\(expandedGroups.contains(row.id) ? "Collapse" : "Expand") \(row.events.count) agent steps")
            .accessibilityValue(range)
            .accessibilityIdentifier("worktree.context.history.group.\(row.id)")
            .padding(.bottom, 12)
            if expandedGroups.contains(row.id) {
                ForEach(row.events) { event in eventRow(event) }
            }
        }
    }

    private func railed<Content: View>(_ events: [WorktreeTimeline.Event], @ViewBuilder content: () -> Content) -> some View {
        let first = events[0]
        let last = events.last?.id == timeline.events.last?.id
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color(for: first)).frame(width: 7, height: 7).padding(.top, 6)
                if !last { Rectangle().fill(secondary.opacity(0.3)).frame(width: 1) }
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 6) {
                if first.timestamp != nil || last {
                    HStack(spacing: 6) {
                        if let timestamp = first.timestamp { Text(Self.time(timestamp)) }
                        if last { Text("Latest") }
                    }
                    .font(.caption2).foregroundStyle(secondary)
                }
                content()
            }
            .padding(.bottom, last ? 0 : 22)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: first.kind == .agentMessage || (first.sourceWorktreePath != nil && openWorktree != nil) ? .contain : .combine)
        .accessibilityIdentifier("worktree.context.history.event.\(first.id)")
    }

    private func eventRow(_ event: WorktreeTimeline.Event) -> some View {
        railed([event]) {
            sender(event, title: event.title)
            if !event.completed.isEmpty {
                Text(event.completed).font(.callout).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(event.decisions.enumerated()), id: \.offset) { _, decision in
                Text(decision).font(.caption).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inputs(_ row: WorktreeTimeline.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You").font(.caption2).foregroundStyle(Color.orange)
            ForEach(row.entries) { entry in
                Text(entry.event.completed).font(.callout).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 10)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.orange.opacity(0.6)).frame(width: 2) }
            }
        }
    }

    private func peerCard(_ row: WorktreeTimeline.Row) -> some View {
        let expanded = expandedGroups.contains(row.id)
        let visible = expanded ? row.entries.count : min(row.entries.count, 2)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right").font(.caption)
                sender(row.events[0], title: row.events[0].sourceWorktreeName ?? row.events[0].title)
                Text(row.events.count == 1 ? "1 message" : "\(row.events.count) messages")
                    .font(.caption2).foregroundStyle(secondary).fixedSize()
            }
            if row.entries.count > 2 {
                Button(expanded ? "Show fewer" : "\(Self.hiddenMessageCount(row, visibleEntries: visible)) earlier") { toggle(row.id) }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 32, alignment: .leading)
                    .accessibilityIdentifier("worktree.context.history.earlier.\(row.id)")
            }
            ForEach(row.entries.suffix(visible)) { entry in
                PeerMessageLine(entry: entry, secondary: secondary, gists: gists)
            }
        }
        .padding(10)
        .background(secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    /// The messages behind the earlier control: the card's message count minus the
    /// messages its visible lines represent, repeats included.
    static func hiddenMessageCount(_ row: WorktreeTimeline.Row, visibleEntries: Int) -> Int {
        row.events.count - row.entries.suffix(visibleEntries).reduce(0) { $0 + $1.count }
    }

    @ViewBuilder
    private func sender(_ event: WorktreeTimeline.Event, title: String) -> some View {
        if let path = event.sourceWorktreePath, let openWorktree {
            Button {
                unavailableWorktree = !openWorktree(path)
            } label: {
                Text(title).font(.callout).fontWeight(.semibold)
                    .lineLimit(event.kind == .agentMessage ? 1 : nil)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(event.title)
            .accessibilityLabel("Open worktree \(path)")
            .accessibilityIdentifier("worktree.context.history.link.\(event.id)")
        } else {
            Text(title)
                .font(.callout).fontWeight(.semibold)
                .lineLimit(event.kind == .agentMessage ? 1 : nil)
                .help(event.title)
                .fixedSize(horizontal: false, vertical: event.kind != .agentMessage)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggle(_ id: String) {
        if !expandedGroups.insert(id).inserted { expandedGroups.remove(id) }
    }

    private func color(for event: WorktreeTimeline.Event) -> Color {
        switch event.kind {
        case .creation: .accentColor
        case .user: .orange
        case .checkpoint, .agentMessage: secondary
        }
    }

    private func groupDateRange(_ row: WorktreeTimeline.Row) -> String {
        guard let first = row.events.first?.timestamp, let last = row.events.last?.timestamp else { return "" }
        let sameDay = Calendar.current.isDate(Self.date(first), inSameDayAs: Self.date(last))
        return sameDay ? "\(Self.time(first)) to \(Self.time(last))"
            : "\(Self.day(Self.date(first))) \(Self.time(first)) to \(Self.day(Self.date(last))) \(Self.time(last))"
    }

    /// The day separator above each row, or nil when the row continues the day shown above it.
    /// A merged run sits under its first event's day, even when its later events cross midnight.
    static func dayLabels(_ rows: [WorktreeTimeline.Row], now: Date = .now) -> [String?] {
        var shownDay: Date?
        return rows.map { row in
            guard let timestamp = row.events[0].timestamp else { return nil }
            let rowDate = date(timestamp)
            defer { shownDay = rowDate }
            if let shownDay, Calendar.current.isDate(shownDay, inSameDayAs: rowDate) { return nil }
            return day(rowDate, now: now)
        }
    }

    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    static func time(_ timestamp: Double) -> String {
        date(timestamp).formatted(date: .omitted, time: .shortened)
    }

    private static func date(_ timestamp: Double) -> Date { Date(timeIntervalSinceReferenceDate: timestamp) }
}

/// One peer message as a single gist line; tapping it reveals the original text.
private struct PeerMessageLine: View {
    let entry: WorktreeTimeline.Row.Entry
    let secondary: Color
    let gists: PeerMessageGistProvider
    @State private var gist: PeerMessageGist?
    @State private var expanded = false

    var body: some View {
        let text = entry.event.completed
        let shown = gist ?? .immediate(text)
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if shown.isGenerated {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(secondary)
                            .accessibilityLabel("Summary")
                    }
                    Text(shown.text).font(.callout).lineLimit(1).truncationMode(.tail)
                    if entry.count > 1 {
                        Text("×\(entry.count)").font(.caption).foregroundStyle(secondary).fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show the full message")
            .accessibilityIdentifier("worktree.context.history.message.\(entry.id)")
            if expanded {
                Text(text).font(.callout).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: text) { gist = await gists.gist(for: text) }
    }
}
