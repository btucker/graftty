import GrafttyProtocol
import SwiftUI

/// The history stays open; peer messages and older runs of agent work can fold.
struct WorktreeHistoryContent: View {
    let timeline: WorktreeTimeline
    let secondary: Color
    @State private var showsAll = false
    @State private var expandedGroups: Set<String> = []

    private var focusedRows: [WorktreeTimeline.Row] { timeline.rows(showAll: false) }
    private var hasGroups: Bool { focusedRows.contains(where: \.isGroup) }

    var body: some View {
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
                ForEach(timeline.rows(showAll: showsAll)) { row in
                    if row.isGroup {
                        group(row)
                    } else if let event = row.events.first {
                        eventRow(event)
                    }
                }
            }
        }
    }

    private func group(_ row: WorktreeTimeline.Row) -> some View {
        let range = groupDateRange(row)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if !expandedGroups.insert(row.id).inserted { expandedGroups.remove(row.id) }
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

    private func eventRow(_ event: WorktreeTimeline.Event) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(color(for: event)).frame(width: 7, height: 7).padding(.top, 6)
                if event.id != timeline.events.last?.id {
                    Rectangle().fill(secondary.opacity(0.3)).frame(width: 1)
                }
            }
            .frame(width: 8)
            VStack(alignment: .leading, spacing: 6) {
                if let timestamp = event.timestamp {
                    Text(date(timestamp)).font(.caption2).foregroundStyle(secondary)
                }
                if event.kind == .agentMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            if !expandedGroups.insert(event.id).inserted { expandedGroups.remove(event.id) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: expandedGroups.contains(event.id) ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(.caption)
                                heading(event)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(secondary)
                        .accessibilityLabel(event.title)
                        .accessibilityValue(expandedGroups.contains(event.id) ? "Expanded" : "Collapsed")
                        .accessibilityIdentifier("worktree.context.history.message.\(event.id)")
                        if expandedGroups.contains(event.id) { details(event) }
                    }
                    .padding(10)
                    .background(secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    heading(event)
                    details(event)
                }
            }
            .padding(.bottom, event.id == timeline.events.last?.id ? 0 : 22)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: event.kind == .agentMessage ? .contain : .combine)
        .accessibilityIdentifier("worktree.context.history.event.\(event.id)")
    }

    private func heading(_ event: WorktreeTimeline.Event) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if event.kind == .user {
                Text("Your input").font(.caption2).foregroundStyle(Color.orange)
            } else {
                Text(event.title).font(.callout).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if event.id == timeline.events.last?.id {
                Text("Latest").font(.caption2).foregroundStyle(secondary)
            }
        }
    }

    @ViewBuilder
    private func details(_ event: WorktreeTimeline.Event) -> some View {
        if !event.completed.isEmpty {
            Text(event.completed).font(.callout).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, event.kind == .user ? 10 : 0)
                .overlay(alignment: .leading) {
                    if event.kind == .user { Rectangle().fill(Color.orange.opacity(0.6)).frame(width: 2) }
                }
        }
        ForEach(Array(event.decisions.enumerated()), id: \.offset) { _, decision in
            Text(decision).font(.caption).foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        return "\(date(first)) to \(date(last))"
    }

    private func date(_ timestamp: Double) -> String {
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        let local = date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
        return local + " " + (TimeZone.current.abbreviation(for: date) ?? TimeZone.current.identifier)
    }
}
