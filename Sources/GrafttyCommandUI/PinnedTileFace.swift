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
    /// Concentric with the shelf, like a selected item in a glass toolbar.
    static let cornerRadius: CGFloat = PinnedTileShelf.cornerRadius - PinnedTileShelf.inset
    /// The working dot, a quiet blue that reads as in progress, not as an alarm.
    static let working = Color(.sRGB, red: 0.48, green: 0.66, blue: 1, opacity: 1)

    let identity: WorktreeIconIdentity
    let project: SidebarProject
    let imageData: Data?
    let word: String
    /// The host, shown under the name only when another pinned agent shares it.
    let hostBadge: String?
    let state: PinnedTileState
    let isSelected: Bool

    public init(identity: WorktreeIconIdentity, project: SidebarProject, imageData: Data? = nil, word: String,
                hostBadge: String?, state: PinnedTileState, isSelected: Bool) {
        self.identity = identity; self.project = project; self.imageData = imageData; self.word = word
        self.hostBadge = hostBadge; self.state = state; self.isSelected = isSelected
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
            // A plain fill: the shelf's glass edge is the only outline, so borders never nest.
            if isSelected { shape.fill(isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08)) }
        }
        .overlay(alignment: .topTrailing) {
            if state == .asleep {
                Image(systemName: "moon.zzz.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
            }
        }
        .opacity(state == .asleep ? 0.55 : 1)
        .contentShape(shape)
    }

    @ViewBuilder private var pip: some View {
        let attention = SidebarAttentionStyle.text(isDark: isDark)
        switch state.pip {
        case .filled?:
            Circle().fill(attention).frame(width: 7, height: 7)
        case .pulse? where reduceMotion:
            Circle().fill(Self.working).frame(width: 7, height: 7)
        case .pulse?:
            // A slow pulse needs no more than 30 frames a second, and agents work for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Circle().fill(Self.working).frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * abs(cos(phase * .pi)))
            }
        case nil:
            EmptyView()
        }
    }
}

/// One glass surface under a whole grid of pinned tiles (LAYOUT-2.242), with a
/// system-material fallback on releases before Liquid Glass.
public struct PinnedTileShelf: ViewModifier {
    public static let cornerRadius: CGFloat = 22
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
