#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// The questions agents are waiting on, one card at a time (IOS-13.20).
/// Swipe sideways between cards; answering happens in the agent's terminal.
struct MobileAskDeck: View {
    struct Entry: Identifiable {
        let row: MergedWorktreeRow
        let context: SidebarWorktreeContext
        let card: AttentionAskCard
        /// Where the question comes from, e.g. `graftty · design-mobile`.
        let source: String
        let time: Date?
        var id: String { row.id }
    }

    let entries: [Entry]
    let onExplain: (Entry) -> Void
    let onOpen: (Entry) -> Void
    let onDismiss: (Entry) -> Void

    @State private var position: String?
    @State private var heights: [String: CGFloat] = [:]

    private var currentID: String? { position ?? entries.first?.id }

    private var currentHeight: CGFloat? { currentID.flatMap { heights[$0] } }

    private var currentIndex: Int {
        position.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(entries) { entry in
                        MobileAskCardView(entry: entry,
                                          onExplain: { onExplain(entry) },
                                          onOpen: { onOpen(entry) },
                                          onDismiss: { onDismiss(entry) })
                            // Narrower than the screen so the next card peeks in.
                            .containerRelativeFrame(.horizontal) { width, _ in entries.count > 1 ? width - 28 : width }
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { heights[entry.id] = $0 }
                            // A taller neighbor is cut to the card in view, with rounded corners.
                            .frame(height: entry.id == currentID ? nil : currentHeight, alignment: .top)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            // Size the deck to the card in view, not the tallest one. The mask
            // clips only vertically, so neighbors still show in the side margins.
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: currentHeight, alignment: .top)
            .mask { Rectangle().padding(.horizontal, -40) }
            .animation(.snappy, value: currentHeight)
            .onChange(of: entries.map(\.id)) { old, new in
                // The card in view was answered or dismissed: follow the card that
                // took its place, or the dots keep pointing at the first card.
                guard let current = position, !new.contains(current) else { return }
                let index = old.firstIndex(of: current) ?? 0
                position = new.isEmpty ? nil : new[min(index, new.count - 1)]
            }
            if entries.count > 1 {
                HStack(spacing: 6) {
                    ForEach(entries.indices, id: \.self) { index in
                        Circle()
                            .fill(index == currentIndex ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Question \(currentIndex + 1) of \(entries.count)")
            }
        }
    }
}

private struct MobileAskCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let entry: MobileAskDeck.Entry
    let onExplain: () -> Void
    let onOpen: () -> Void
    let onDismiss: () -> Void

    private var card: AttentionAskCard { entry.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Text(card.question)
                .font(.system(size: 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let catchUp = card.catchUp {
                context(label: "Catch-up", text: catchUp)
            } else if let completed = card.lastCompleted {
                context(label: "Last did", text: completed)
            }
            HStack(spacing: 8) {
                Button(action: onExplain) {
                    Text("Explain more").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                Button(action: onOpen) {
                    // A primary tint is white in dark mode; keep the label legible on it.
                    Text("Open").frame(maxWidth: .infinity)
                        .foregroundStyle(Color(uiColor: .systemBackground))
                }
                .buttonStyle(.borderedProminent)
                .tint(.primary)
            }
            .controlSize(.large)
            .fontWeight(.semibold)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text([entry.source, card.agentName].compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1)
            Spacer(minLength: 4)
            if let time = entry.time {
                TimelineView(.periodic(from: .now, by: 60)) { timeline in
                    Text(WorktreeActivitySections.ageText(since: time, now: timeline.date))
                }
                .fixedSize()
            }
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -8)
            .accessibilityLabel("Dismiss request")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private func context(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(SidebarAttentionStyle.text(isDark: colorScheme == .dark))
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(SidebarAttentionStyle.text(isDark: colorScheme == .dark).opacity(0.5))
                .frame(width: 3)
        }
    }
}
#endif
