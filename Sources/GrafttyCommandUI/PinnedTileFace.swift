import SwiftUI
import GrafttyProtocol

/// A pinned agent's tile, the same on Mac and mobile: its icon with its name
/// below, sitting bare on the shared glass shelf (LAYOUT-2.242). Only the
/// selected tile gets a pad of its own, and status is one small pip before the
/// name (LAYOUT-2.225), so a tile never carries more than one cue.
public struct PinnedTileFace: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public static let height: CGFloat = 64
    static let cornerRadius: CGFloat = 12
    /// The working dots, a quiet blue that reads as in progress, not as an alarm.
    static let working = Color(.sRGB, red: 0.48, green: 0.66, blue: 1, opacity: 1)

    let identity: WorktreeIconIdentity
    let project: SidebarProject
    let imageData: Data?
    let word: String
    /// The host, shown under the name only when another pinned agent shares it.
    let hostBadge: String?
    let state: PinnedTileState
    let isSelected: Bool
    let selectedFill: Color

    public init(identity: WorktreeIconIdentity, project: SidebarProject, imageData: Data? = nil, word: String,
                hostBadge: String?, state: PinnedTileState, isSelected: Bool, selectedFill: Color) {
        self.identity = identity; self.project = project; self.imageData = imageData; self.word = word
        self.hostBadge = hostBadge; self.state = state; self.isSelected = isSelected
        self.selectedFill = selectedFill
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }
    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        VStack(spacing: 3) {
            Group {
                if identity == .none {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 17)).foregroundStyle(.secondary)
                } else {
                    WorktreeIdentityView(identity: identity, project: project, imageData: imageData, size: 36, maxWidth: 54)
                }
            }
            // Full colour whatever the state: on a bare shelf a faded drawing just looks washed out.
            .frame(height: 36)
            HStack(spacing: 4) {
                pip
                Text(word)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.tail)
            }
            if let hostBadge {
                Text(hostBadge)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.horizontal, 3).padding(.vertical, 5)
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .background {
            if isSelected {
                shape.fill(selectedFill)
                    .overlay(shape.strokeBorder(.white.opacity(isDark ? 0.22 : 0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if state == .asleep {
                Image(systemName: "moon.zzz.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
            }
        }
        .opacity(state == .asleep ? 0.55 : 1)
        .contentShape(shape)
    }

    /// Three small dots; `lit` brightens one of them, nil keeps all three steady.
    private func workingDots(lit: Int?) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                Circle().fill(Self.working).frame(width: 4, height: 4)
                    .opacity(lit.map { $0 == index ? 1 : 0.35 } ?? 1)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var pip: some View {
        let attention = SidebarAttentionStyle.text(isDark: isDark)
        switch state.pip {
        case .filled?:
            Circle().fill(attention).frame(width: 7, height: 7)
        case .ring?:
            Circle().strokeBorder(attention, lineWidth: 1.5).frame(width: 7, height: 7)
        case .dots? where reduceMotion:
            workingDots(lit: nil)
        case .dots?:
            // Three dots light in turn; 15 frames a second is plenty, and agents work for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 15)) { timeline in
                let step = Int(timeline.date.timeIntervalSinceReferenceDate / 0.35) % 3
                workingDots(lit: step)
            }
        case nil:
            EmptyView()
        }
    }
}

/// One glass surface under a whole grid of pinned tiles (LAYOUT-2.242), with a
/// system-material fallback on releases before Liquid Glass.
public struct PinnedTileShelf: ViewModifier {
    public static let cornerRadius: CGFloat = 18
    public static let inset: CGFloat = 6

    public init() {}

    @ViewBuilder public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        if #available(macOS 26.0, iOS 26.0, *) {
            content.padding(Self.inset).glassEffect(.regular, in: shape)
        } else {
            content.padding(Self.inset).background(.regularMaterial, in: shape)
        }
    }
}

extension View {
    public func pinnedTileShelf() -> some View { modifier(PinnedTileShelf()) }

    /// A tile reads as one button, named for its agent, host, and state.
    public func pinnedTileAccessibility(name: String, host: String?, state: PinnedTileState, isSelected: Bool,
                                        open: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(PinnedTile.accessibilityLabel(name: name, host: host, state: state))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open() }
    }
}
