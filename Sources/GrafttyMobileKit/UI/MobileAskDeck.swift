#if canImport(UIKit)
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// The questions agents are waiting on, one card at a time (IOS-13.20).
/// Stacked: swipe right to open the agent, left for later; answering happens in its terminal.
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

    @State private var frontID: String?
    @State private var dragX: CGFloat = 0

    /// How many cards show their edges beneath the front one.
    private static let visibleBehind = 2
    private static let behindStep: CGFloat = 7

    private var frontIndex: Int {
        frontID.flatMap { id in entries.firstIndex { $0.id == id } } ?? 0
    }

    var body: some View {
        let behind = min(entries.count - 1, Self.visibleBehind)
        VStack(spacing: 10) {
            ZStack {
                if entries.indices.contains(frontIndex) {
                    let front = entries[frontIndex]
                    MobileAskCardView(entry: front,
                                      onExplain: { onExplain(front) },
                                      onOpen: { onOpen(front) },
                                      onDismiss: { onDismiss(front) })
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(alignment: dragX > 0 ? .topLeading : .topTrailing) { swipeHint }
                        .offset(x: dragX)
                        .rotationEffect(.degrees(Double(dragX) / 40), anchor: .bottom)
                        .simultaneousGesture(swipe(front))
                        .accessibilityAction(named: "Later") { advance() }
                        .id(front.id)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.94, anchor: .bottom).combined(with: .opacity),
                            removal: .opacity))
                }
            }
            // The rest of the stack: plain edges under the front card, so the
            // deck's height only changes when the front card does.
            .background(alignment: .top) {
                ZStack {
                    ForEach(Array(stride(from: behind, through: 1, by: -1)), id: \.self) { depth in
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(uiColor: .secondarySystemGroupedBackground))
                            .opacity(depth == 1 ? 0.7 : 0.45)
                            .padding(.horizontal, CGFloat(depth) * 10)
                            .offset(y: CGFloat(depth) * Self.behindStep)
                    }
                }
            }
            .padding(.bottom, CGFloat(max(behind, 0)) * Self.behindStep)
            .onChange(of: entries.map(\.id)) { old, new in
                // The front card was answered or dismissed: the card behind it
                // comes forward.
                guard let current = frontID, !new.contains(current) else { return }
                let index = old.firstIndex(of: current) ?? 0
                frontID = new.isEmpty ? nil : new[min(index, new.count - 1)]
            }
            if entries.count > 1 {
                HStack(spacing: 6) {
                    ForEach(entries.indices, id: \.self) { index in
                        Circle()
                            .fill(index == frontIndex ? Color.primary.opacity(0.7) : Color.secondary.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Question \(frontIndex + 1) of \(entries.count)")
            }
        }
    }

    /// Right opens the agent's pane; left puts the card at the back of the
    /// stack. Simultaneous so the list still scrolls; only a sideways drag counts.
    private func swipe(_ front: Entry) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // Nothing to go back to with a single card, so left barely moves.
                dragX = entries.count > 1 || value.translation.width > 0 ? value.translation.width : value.translation.width / 4
            }
            .onEnded { value in
                let far = abs(value.translation.width) > Self.swipeDistance
                    || abs(value.predictedEndTranslation.width) > 2 * Self.swipeDistance
                let direction = dragX
                withAnimation(.snappy) {
                    if far, direction < 0 { advance() }
                    dragX = 0
                }
                if far, direction > 0 { onOpen(front) }
            }
    }

    private static let swipeDistance: CGFloat = 90

    /// Names what letting go will do, growing clearer as the drag nears the threshold.
    @ViewBuilder private var swipeHint: some View {
        if dragX != 0, dragX > 0 || entries.count > 1 {
            Text(dragX > 0 ? "Open" : "Later")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(dragX > 0 ? Color(uiColor: .systemBackground) : .primary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(dragX > 0 ? Color.primary : Color(uiColor: .tertiarySystemFill), in: Capsule())
                .padding(12)
                .opacity(min(abs(dragX) / Self.swipeDistance, 1))
        }
    }

    private func advance() {
        guard entries.count > 1 else { return }
        frontID = entries[(frontIndex + 1) % entries.count].id
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
