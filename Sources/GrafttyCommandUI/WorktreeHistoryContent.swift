import GrafttyProtocol
import SwiftUI

/// A quiet rail aligns all messages; older runs of agent work can fold.
struct WorktreeHistoryContent: View {
    let timeline: WorktreeTimeline
    let secondary: Color
    var openWorktree: ((String) -> Bool)? = nil
    var gists: PeerMessageGistProvider = .shared
    /// Scrolls the agent terminal to a message by event id; nil when no agent pane is known.
    var revealInTerminal: (@MainActor (String) async -> Bool)? = nil
    @State private var showsAll = false
    /// The message whose last reveal found nothing, shown briefly beneath it.
    @State private var missingInTerminal: String?
    @State private var expandedGroups: Set<String> = []
    /// Separate from `expandedGroups`: a fold's id is its first entry's id.
    @State private var expandedEntries: Set<String> = []
    @State private var unavailableWorktree = false

    var body: some View {
        let focused = timeline.rows(showAll: false)
        let hasGroups = focused.contains(where: \.isGroup)
        let rows = showsAll ? timeline.rows(showAll: true) : focused
        let days = Self.dayLabels(rows)
        VStack(alignment: .leading, spacing: 16) {
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
                    case .inputs: railed(row.events, sender: "You") { inputs(row) } below: { EmptyView() }
                    case .peerMessages:
                        railed(row.events, sender: row.events[0].sourceWorktreeName ?? row.events[0].title) { peerMessages(row) } below: { EmptyView() }
                    case .agentTurn:
                        railed(row.events) {
                            TimelineMessageLine(event: row.events[0], turn: row, secondary: secondary, gists: gists,
                                reveal: revealInTerminal == nil ? nil : { reveal(row.id) })
                        } below: {
                            missingNote(row.id)
                        }
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

    /// One quiet row: rail dot, an optional sender, the row's line, and its time
    /// on the same baseline, with anything opened from it below (CONTEXT-19).
    private func railed<Line: View, Below: View>(_ events: [WorktreeTimeline.Event], sender: String? = nil,
                                               @ViewBuilder line: () -> Line,
                                               @ViewBuilder below: () -> Below) -> some View {
        let first = events[0]
        let last = events.last?.id == timeline.events.last?.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(color(for: first)).frame(width: 6, height: 6).padding(.top, 7)
                if !last { Rectangle().fill(secondary.opacity(0.2)).frame(width: 1) }
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 6) {
                // The time overlays a reserved margin rather than sharing the row, so the
                // line always wraps at one definite width and the row's height never shifts.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if let sender { self.sender(first, title: sender) }
                    line().frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.trailing, first.timestamp == nil ? 0 : Self.timeWidth)
                .overlay(alignment: .topTrailing) {
                    if let timestamp = first.timestamp {
                        Text(Self.time(timestamp)).font(.caption2).foregroundStyle(secondary)
                            .lineLimit(1).padding(.top, 3)
                    }
                }
                below()
            }
            .padding(.bottom, last ? 0 : 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: first.presentation != nil || first.kind == .agentMessage || first.kind == .agentResponse || (first.sourceWorktreePath != nil && openWorktree != nil) ? .contain : .combine)
        .accessibilityIdentifier("worktree.context.history.event.\(first.id)")
    }

    /// A history entry's detail and decisions, shown only once its row is activated (CONTEXT-60).
    static func entryDetail(_ event: WorktreeTimeline.Event, expanded: Bool)
        -> (detail: String?, decisions: [String], hasMore: Bool) {
        let detail = event.completed.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMore = !detail.isEmpty || !event.decisions.isEmpty
        guard expanded else { return (nil, [], hasMore) }
        return (detail.isEmpty ? nil : detail, event.decisions, hasMore)
    }

    @ViewBuilder
    private func eventRow(_ event: WorktreeTimeline.Event) -> some View {
        if event.kind == .checkpoint, event.presentation == nil {
            entryRow(event)
        } else {
            detailedEventRow(event)
        }
    }

    /// A headline on one row with its time; the detail opens in place. A button,
    /// like the other toggles here, so selectable text and VoiceOver activate it.
    @ViewBuilder
    private func entryRow(_ event: WorktreeTimeline.Event) -> some View {
        let expanded = expandedEntries.contains(event.id)
        let shown = Self.entryDetail(event, expanded: expanded)
        let row = railed([event]) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(event.title).font(.callout).fontWeight(.medium).lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                if shown.hasMore {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(secondary)
                }
            }
        } below: {
            if let detail = shown.detail {
                Text(detail).font(.callout).foregroundStyle(secondary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(shown.decisions.enumerated()), id: \.offset) { _, decision in
                Text(decision).font(.caption).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if shown.hasMore {
            Button {
                expandedEntries.formSymmetricDifference([event.id])
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("worktree.context.history.event.\(event.id)")
        } else {
            row
        }
    }

    private func detailedEventRow(_ event: WorktreeTimeline.Event) -> some View {
        railed([event], sender: event.title) {
            if let presentation = event.presentation {
                HarnessTimelineContent(presentation: presentation, secondary: secondary, wasTruncated: event.wasTruncated)
            } else if !event.completed.isEmpty {
                Text(event.completed).font(.callout).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } below: {
            ForEach(Array(event.decisions.enumerated()), id: \.offset) { _, decision in
                Text(decision).font(.caption).foregroundStyle(secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func inputs(_ row: WorktreeTimeline.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(row.entries) { entry in
                if let presentation = entry.event.presentation {
                    HarnessTimelineContent(presentation: presentation, secondary: secondary, wasTruncated: entry.event.wasTruncated)
                    if revealInTerminal != nil {
                        Button("Show in terminal") { reveal(entry.event.id) }
                            .font(.caption).buttonStyle(.plain).foregroundStyle(secondary)
                    }
                } else {
                    let line = Text(entry.event.completed).font(.callout).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if revealInTerminal != nil {
                        Button { reveal(entry.event.id) } label: { line.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .help("Show in terminal")
                            .accessibilityHint("Show this message in the terminal")
                            .accessibilityIdentifier("worktree.context.history.reveal.\(entry.id)")
                    } else {
                        line
                    }
                }
                missingNote(entry.event.id)
            }
        }
    }

    private func peerMessages(_ row: WorktreeTimeline.Row) -> some View {
        let expanded = expandedGroups.contains(row.id)
        let visible = expanded ? row.entries.count : min(row.entries.count, 2)
        return VStack(alignment: .leading, spacing: 8) {
            if row.events.count > 1 {
                Text("\(row.events.count) messages")
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
                TimelineMessageLine(event: entry.event, count: entry.count, secondary: secondary, gists: gists,
                    reveal: revealInTerminal == nil ? nil : { reveal(entry.event.id) })
                missingNote(entry.event.id)
            }
        }
    }

    /// The messages behind the earlier control: the run's message count minus the
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
                // A fixed width keeps every layout pass wrapping the line beside it the same way.
                Text(title).font(.caption).fontWeight(.semibold).lineLimit(1).fixedSize()
                    #if os(iOS)
                    .frame(minHeight: 44, alignment: .topLeading)
                    #endif
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help(event.title)
            .accessibilityLabel("Open worktree \(path)")
            .accessibilityIdentifier("worktree.context.history.link.\(event.id)")
        } else {
            Text(title)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(event.kind == .user ? Color.orange : .primary)
                .help(event.title)
                .lineLimit(1)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func missingNote(_ eventID: String) -> some View {
        if missingInTerminal == eventID {
            Text("Not in terminal history").font(.caption2).foregroundStyle(secondary)
                .padding(.leading, 10)
                .accessibilityIdentifier("worktree.context.history.missing.\(eventID)")
        }
    }

    /// A message the terminal no longer holds gets a brief note instead of an alert.
    private func reveal(_ eventID: String) {
        guard let revealInTerminal else { return }
        Task { @MainActor in
            guard !(await revealInTerminal(eventID)) else {
                if missingInTerminal == eventID { missingInTerminal = nil }
                return
            }
            missingInTerminal = eventID
            try? await Task.sleep(for: .seconds(3))
            if missingInTerminal == eventID { missingInTerminal = nil }
        }
    }

    private func toggle(_ id: String) {
        if !expandedGroups.insert(id).inserted { expandedGroups.remove(id) }
    }

    private func color(for event: WorktreeTimeline.Event) -> Color {
        switch event.kind {
        case .creation: .accentColor
        case .user: .orange
        case .checkpoint, .agentMessage, .agentResponse, .system: secondary
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

    /// Room reserved for a short local time such as 12:59 PM.
    static let timeWidth: CGFloat = 64

    static func time(_ timestamp: Double) -> String {
        date(timestamp).formatted(date: .omitted, time: .shortened)
    }

    private static func date(_ timestamp: Double) -> Date { Date(timeIntervalSinceReferenceDate: timestamp) }
}

/// One line per message, so a summary arriving never moves the rows after it.
struct TimelineMessageLine: View {
    let event: WorktreeTimeline.Event
    var turn: WorktreeTimeline.Row? = nil
    var count: Int = 1
    let secondary: Color
    let gists: PeerMessageGistProvider
    var reveal: (() -> Void)? = nil
    @State private var gist: PeerMessageGist?
    @State private var expanded = false

    private struct Request: Hashable {
        let text: String
        let isReady: Bool
    }

    var body: some View {
        let text = turn?.fullText ?? event.completed
        let request = Request(text: turn?.summaryInput ?? text, isReady: turn?.isComplete ?? true)
        let fallback = turn?.events.last?.completed ?? text
        let firstResponse = turn.map { PeerMessageGist(text: $0.events[0].completed, isGenerated: false) }
        let shown = gist ?? firstResponse ?? PeerMessageGist.verbatim(request.text)
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                // One line whatever the text, so a summary arriving never moves later rows.
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if shown?.isGenerated == true {
                        Image(systemName: "sparkles").font(.caption2).foregroundStyle(secondary)
                            .accessibilityLabel("AI summary")
                    }
                    if let shown {
                        Text(shown.text).font(.callout).foregroundStyle(secondary)
                            .lineLimit(1).truncationMode(.tail)
                    } else {
                        Text("Ag").font(.callout).hidden().frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .leading) { skeleton }
                    }
                    if !request.isReady {
                        Text("Working…").font(.caption).italic().foregroundStyle(secondary).fixedSize()
                    }
                    if count > 1 {
                        Text("×\(count)").font(.caption).foregroundStyle(secondary).fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityLabel(shown?.text ?? (request.isReady ? "Summarizing agent messages" : "Agent turn in progress"))
            .accessibilityHint(turn == nil ? "Show the full message" : "Show all captured messages in this turn")
            .accessibilityIdentifier("worktree.context.history.message.\(event.id)")
            .contextMenu {
                if let reveal { Button("Show in Terminal", systemImage: "terminal", action: reveal) }
            }
            if expanded {
                Text(text).font(.callout).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let reveal {
                    Button("Show in terminal", action: reveal)
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .frame(minHeight: 32, alignment: .leading)
                        .accessibilityIdentifier("worktree.context.history.reveal.\(event.id)")
                }
            }
        }
        .task(id: request) {
            gist = nil
            guard request.isReady else { return }
            let result = await gists.gist(for: request.text)
            guard !Task.isCancelled else { return }
            gist = result.isGenerated ? result : .immediate(fallback)
        }
    }

    private var skeleton: some View {
        GeometryReader { geometry in
            RoundedRectangle(cornerRadius: 3)
                .fill(secondary.opacity(0.16))
                .frame(width: geometry.size.width * 0.8, height: 8)
                .frame(maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}
