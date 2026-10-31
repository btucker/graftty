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
                    case .inputs: railed(row.events, title: "You") { inputs(row) }
                    case .peerMessages:
                        railed(row.events, title: row.events[0].sourceWorktreeName ?? row.events[0].title) { peerMessages(row) }
                    case .agentTurn:
                        railed(row.events) {
                            TimelineMessageLine(event: row.events[0], turn: row, secondary: secondary, gists: gists,
                                reveal: revealInTerminal == nil ? nil : { reveal(row.id) })
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

    private func railed<Content: View>(_ events: [WorktreeTimeline.Event], title: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        let first = events[0]
        let last = events.last?.id == timeline.events.last?.id
        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle().fill(color(for: first)).frame(width: 6, height: 6).padding(.top, 7)
                if !last { Rectangle().fill(secondary.opacity(0.2)).frame(width: 1) }
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    sender(first, title: title ?? first.title)
                    Spacer(minLength: 0)
                    if let timestamp = first.timestamp {
                        Text(Self.time(timestamp)).font(.caption2).foregroundStyle(secondary).fixedSize()
                    }
                }
                content()
                if last { Text("Latest").font(.caption2).foregroundStyle(secondary) }
            }
            .padding(.bottom, last ? 0 : 22)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: first.presentation != nil || first.kind == .agentMessage || first.kind == .agentResponse || (first.sourceWorktreePath != nil && openWorktree != nil) ? .contain : .combine)
        .accessibilityIdentifier("worktree.context.history.event.\(first.id)")
    }

    private func eventRow(_ event: WorktreeTimeline.Event) -> some View {
        railed([event]) {
            if let presentation = event.presentation {
                HarnessTimelineContent(presentation: presentation, secondary: secondary, wasTruncated: event.wasTruncated)
            } else if !event.completed.isEmpty {
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
                Text(title).font(.caption).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
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

    static func time(_ timestamp: Double) -> String {
        date(timestamp).formatted(date: .omitted, time: .shortened)
    }

    private static func date(_ timestamp: Double) -> Date { Date(timeIntervalSinceReferenceDate: timestamp) }
}

/// Fixed preview space keeps generation from moving the rest of the timeline.
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
        VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 6) {
                        // Lay out four actual lines once. Text and skeleton are overlays,
                        // so differing glyph metrics cannot change the row's height.
                        Text("Ag\nAg\nAg\nAg").font(.callout).lineSpacing(2).hidden()
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .overlay(alignment: .topLeading) {
                                if let shown {
                                    Text(shown.text).font(.callout).lineSpacing(2)
                                        .lineLimit(4).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                } else {
                                    skeleton
                                }
                            }
                        if count > 1 {
                            Text("×\(count)").font(.caption).foregroundStyle(secondary).fixedSize()
                        }
                    }
                    // Reserve the same footer before and after the generated label arrives.
                    HStack {
                        Label("AI summary", systemImage: "sparkles").hidden().fixedSize()
                            .overlay(alignment: .leading) {
                                if !request.isReady {
                                    Text("Working…")
                                } else if gist == nil, PeerMessageGist.verbatim(request.text) == nil {
                                    Text("Summarizing…")
                                } else if shown?.isGenerated == true {
                                    Label("AI summary", systemImage: "sparkles").fixedSize()
                                }
                            }
                        Spacer(minLength: 8)
                        Text(expanded ? "Show less" : "Show more")
                    }
                    .font(.caption2).foregroundStyle(secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
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
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array([0.94, 0.83, 0.91, 0.58].enumerated()), id: \.offset) { _, fraction in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(secondary.opacity(0.16))
                        .frame(width: geometry.size.width * fraction, height: 8)
                }
            }
            .padding(.top, 4)
        }
        .accessibilityHidden(true)
    }
}
