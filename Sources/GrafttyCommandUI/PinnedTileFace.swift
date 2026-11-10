import SwiftUI
import GrafttyProtocol

/// A pinned agent's tile, the same on Mac and mobile: its icon, a word on a
/// dark band, and a border that lights up in place. Only the states in
/// `PinnedTileState` draw anything, so a tile never carries more than one cue.
public struct PinnedTileFace: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public static let height: CGFloat = 50
    static let cornerRadius: CGFloat = 10
    /// The working ring, a quiet blue that reads as in progress, not as an alarm.
    static let working = Color(.sRGB, red: 0.48, green: 0.66, blue: 1, opacity: 1)

    let identity: WorktreeIconIdentity
    let project: SidebarProject
    let imageData: Data?
    let word: String
    let hostBadge: String?
    let state: PinnedTileState
    let isSelected: Bool
    let fill: Color
    let selectedFill: Color

    public init(identity: WorktreeIconIdentity, project: SidebarProject, imageData: Data? = nil, word: String,
                hostBadge: String?, state: PinnedTileState, isSelected: Bool, fill: Color, selectedFill: Color) {
        self.identity = identity; self.project = project; self.imageData = imageData; self.word = word
        self.hostBadge = hostBadge; self.state = state; self.isSelected = isSelected
        self.fill = fill; self.selectedFill = selectedFill
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }
    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        ZStack {
            shape.fill(isSelected ? selectedFill : fill)
            Group {
                if identity == .none {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 17)).foregroundStyle(.secondary)
                } else {
                    WorktreeIdentityView(identity: identity, project: project, imageData: imageData, size: 36, maxWidth: 54)
                }
            }
                .opacity(state == .idle ? (isDark ? 0.55 : 0.6) : 1)
                .offset(y: -6)
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .overlay(alignment: .bottom) { band }
        .overlay(alignment: .topLeading) { badge }
        .overlay(alignment: .topTrailing) {
            if state == .asleep {
                Image(systemName: "moon.zzz.fill").font(.system(size: 8)).foregroundStyle(.secondary).padding(4)
            }
        }
        .clipShape(shape)
        .overlay { border }
        .opacity(state == .asleep ? 0.55 : 1)
        .contentShape(shape)
    }

    private var band: some View {
        Text(word)
            .font(.system(size: 9.5, weight: .semibold))
            .lineLimit(1).truncationMode(.tail)
            .foregroundStyle(.white)
            .padding(.horizontal, 4).padding(.top, 6).padding(.bottom, 2)
            .frame(maxWidth: .infinity)
            .background(LinearGradient(colors: [.black.opacity(0), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var badge: some View {
        if let hostBadge {
            Text(hostBadge)
                .font(.system(size: 7.5, weight: .bold))
                .lineLimit(1).truncationMode(.tail)
                .foregroundStyle(.white)
                .padding(.horizontal, 3).padding(.vertical, 1)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 3))
                .padding(3)
                .frame(maxWidth: 44, alignment: .leading)
        }
    }

    @ViewBuilder private var border: some View {
        switch state {
        case .waiting:
            shape.strokeBorder(SidebarAttentionStyle.text(isDark: isDark), lineWidth: 2)
        case .working where reduceMotion:
            shape.strokeBorder(Self.working, lineWidth: 2)
        case .working:
            // A slow ring needs no more than 30 frames a second, and agents work for hours.
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
                let turn = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4
                shape.strokeBorder(AngularGradient(colors: [Self.working, Self.working.opacity(0), Self.working],
                                                   center: .center, angle: .degrees(turn * 360)), lineWidth: 2)
            }
        case .asleep, .idle:
            EmptyView()
        }
    }
}

extension View {
    /// A tile reads as one button, named for its agent, host, and state.
    public func pinnedTileAccessibility(name: String, host: String?, state: PinnedTileState, isSelected: Bool,
                                        open: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(PinnedTile.accessibilityLabel(name: name, host: host, state: state))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { open() }
    }
}
