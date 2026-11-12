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
    /// The working dot, a quiet blue that reads as in progress, not as an alarm;
    /// deeper in light mode so it still reads on a pale niche.
    static func working(isDark: Bool) -> Color {
        isDark ? Color(.sRGB, red: 0.48, green: 0.66, blue: 1, opacity: 1) : Color(.sRGB, red: 0, green: 0.45, blue: 0.95, opacity: 1)
    }
    /// The attention dot: plain orange in both modes (the attention text colour darkens in light mode for legibility).
    static let attention = Color(.sRGB, red: 1, green: 0.58, blue: 0.05, opacity: 1)

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
            // Dark: a light pill. Light: a white pill lifted by a hairline shadow, like a
            // selected segment, so it reads brighter than the niche in both.
            if isSelected {
                if isDark {
                    shape.fill(Color.white.opacity(0.16))
                } else {
                    shape.fill(Color.white).shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                }
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

    @ViewBuilder private var pip: some View {
        let working = Self.working(isDark: isDark)
        switch state.pip {
        case .filled?:
            Circle().fill(Self.attention).frame(width: 7, height: 7)
        case .pulse? where reduceMotion:
            Circle().fill(working).frame(width: 7, height: 7)
        case .pulse?:
            // A slow pulse needs no more than 30 frames a second, and agents work for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                Circle().fill(working).frame(width: 7, height: 7)
                    .opacity(0.35 + 0.65 * abs(cos(phase * .pi)))
            }
        case nil:
            EmptyView()
        }
    }
}

/// One niche under a whole grid of pinned tiles (LAYOUT-2.242): darker than
/// the sidebar, with a soft shadow along its top inner edge and a faint rim
/// light along its bottom, so it reads as cut into the sidebar and a selected
/// tile's light pad stands out against it.
public struct PinnedTileShelf: ViewModifier {
    public static let cornerRadius: CGFloat = 22
    public static let inset: CGFloat = 6
    @Environment(\.colorScheme) private var colorScheme

    public init() {}

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        let isDark = colorScheme == .dark
        content
            .padding(Self.inset)
            .background {
                shape
                    .fill(Color.black.opacity(isDark ? 0.24 : 0.07)
                        .shadow(.inner(color: .black.opacity(isDark ? 0.55 : 0.18), radius: 3, x: 0, y: 1.5)))
                    .overlay {
                        shape.strokeBorder(LinearGradient(colors: [.clear, .white.opacity(isDark ? 0.08 : 0.6)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
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
