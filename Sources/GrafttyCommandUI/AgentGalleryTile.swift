import SwiftUI

/// One agent in the gallery: a live miniature of its terminal, a two-line
/// caption, and its scroll rail on the right edge, so a tile follows the same
/// rule as the stage (a terminal, then its rail).
public struct AgentGalleryTile<Thumbnail: View, Rail: View>: View {
    public static var railWidth: CGFloat { 16 }
    public static var cornerRadius: CGFloat { 6 }

    let title: String
    let provider: String?
    let status: AgentTileStatus
    let isOnStage: Bool
    let foreground: Color
    let background: Color
    let thumbnail: Thumbnail
    let rail: Rail
    let decorateBody: (AnyView) -> AnyView
    let compact: Bool

    /// `decorateBody` wraps the thumbnail and caption, not the rail, so a
    /// click or drag on the tile never competes with the rail's own pointer input.
    /// A `compact` tile is its caption alone, as a finished agent's is (LAYOUT-2.262).
    public init(title: String, provider: String?, status: AgentTileStatus, isOnStage: Bool, foreground: Color, background: Color,
                compact: Bool = false, decorateBody: @escaping (AnyView) -> AnyView = { $0 },
                @ViewBuilder thumbnail: () -> Thumbnail, @ViewBuilder rail: () -> Rail) {
        self.title = title; self.provider = provider; self.status = status; self.isOnStage = isOnStage
        self.foreground = foreground; self.background = background
        self.decorateBody = decorateBody; self.compact = compact
        self.thumbnail = thumbnail(); self.rail = rail()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }

    public var body: some View {
        HStack(spacing: 0) {
            decorateBody(AnyView(tileBody))
            Color.clear.frame(width: Self.railWidth)
        }
        .background(background, in: shape)
        .overlay {
            shape.strokeBorder(foreground.opacity(isOnStage ? 0.7 : 0.12), lineWidth: isOnStage ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        // Above the border and not clipped: the rail's preview cards spill over the tile and the stage.
        .overlay(alignment: .trailing) {
            rail
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity)
                .background(foreground.opacity(0.03))
                .overlay(alignment: .leading) { foreground.opacity(0.1).frame(width: 1) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isOnStage ? [.isButton, .isSelected] : .isButton)
    }

    private var tileBody: some View {
            VStack(alignment: .leading, spacing: 0) {
                if !compact {
                    thumbnail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .opacity(status.isDimmed ? 0.55 : 1)
                        // Over the miniature's corner, where it costs the caption no width (LAYOUT-2.263).
                        .overlay(alignment: .topLeading) {
                            AgentProviderIcon(provider: provider, size: 13)
                                .foregroundStyle(foreground.opacity(0.9))
                                .padding(3)
                                .background(background.opacity(0.85), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .padding(4)
                                .accessibilityHidden(true)
                        }
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        if compact { AgentProviderIcon(provider: provider, size: 12).accessibilityHidden(true) }
                        AgentStatusDot(dot: status.dot)
                        Text(title).font(.system(size: 11.5, weight: isOnStage ? .semibold : .medium))
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Text(status.caption).font(.system(size: 10.5))
                        .foregroundStyle(foreground.opacity(0.6))
                        .lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(foreground.opacity(status.isDimmed ? 0.5 : 1))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: compact ? .infinity : nil, alignment: .leading)
                .background(foreground.opacity(0.06))
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, bottomLeadingRadius: Self.cornerRadius,
                                              style: .continuous))
            .contentShape(Rectangle())
    }

    private var accessibilityText: String {
        var parts = [title]
        if status.dot == .asking { parts.append("asking you") } else if status.dot == .working { parts.append("working") }
        parts.append(status.caption)
        if isOnStage { parts.append("on stage") }
        return parts.joined(separator: ", ")
    }
}

/// Which chrome a stage pane carries, on Mac and GrafttyMobile.
public enum StagePaneChrome {
    /// A split stage names each pane in a slim header. A lone pane has none:
    /// its controls float over its top trailing corner (LAYOUT-2.257).
    public static func showsHeader(paneCount: Int) -> Bool { paneCount > 1 }
}

/// Finished agents sit below the live tiles, collapsed until the user opens
/// the section (LAYOUT-2.262).
public enum AgentGalleryFinished {
    public static let expandedKey = "agentGallery.showsFinished"
    public static var rowHeight: CGFloat { 44 }

    public static func split<Tile>(_ tiles: [Tile], status: (Tile) -> AgentTileStatus) -> (active: [Tile], finished: [Tile]) {
        (tiles.filter { !status($0).isFinished }, tiles.filter { status($0).isFinished })
    }

    public static func title(count: Int) -> String { "Finished · \(count)" }
}

/// The disclosure row above a gallery's finished agents.
public struct AgentGalleryFinishedHeader: View {
    let count: Int
    @Binding var isExpanded: Bool
    let foreground: Color

    public init(count: Int, isExpanded: Binding<Bool>, foreground: Color) {
        self.count = count; _isExpanded = isExpanded; self.foreground = foreground
    }

    public var body: some View {
        Button { withAnimation(.snappy(duration: 0.18)) { isExpanded.toggle() } } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Text(AgentGalleryFinished.title(count: count)).font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Finished agents, \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// The last tile in every gallery, for starting another agent in the worktree.
public struct AgentGalleryEmptyTile: View {
    let worktreePath: String
    let foreground: Color

    public init(worktreePath: String, foreground: Color) { self.worktreePath = worktreePath; self.foreground = foreground }

    /// Names the worktree the agent joins, by its folder.
    public static func title(worktreePath: String) -> String {
        let name = worktreePath.split(separator: "/").last.map(String.init) ?? ""
        return name.isEmpty ? "Add agent" : "Add agent to \(name)"
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AgentGalleryTile<EmptyView, EmptyView>.cornerRadius, style: .continuous)
        Label(Self.title(worktreePath: worktreePath), systemImage: "plus")
            .lineLimit(1).truncationMode(.middle)
            .padding(.horizontal, 8)
            .font(.system(size: 12))
            .foregroundStyle(foreground.opacity(0.6))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay { shape.strokeBorder(foreground.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])) }
            .contentShape(shape)
    }
}

/// A miniature of a terminal's screen drawn from its text: cheap, and it never
/// touches the terminal's grid.
public struct TerminalTextThumbnail: View {
    let rows: [String]
    let columns: Int
    let foreground: Color

    public init(rows: [String], columns: Int, foreground: Color) {
        self.rows = rows; self.columns = max(1, columns); self.foreground = foreground
    }

    public var body: some View {
        Canvas { context, size in
            let fontSize = max(2, size.width / CGFloat(columns) / 0.6)
            let lineHeight = fontSize * 1.2
            let fitting = max(1, Int(size.height / lineHeight))
            let shown = rows.suffix(fitting)
            var y = size.height - CGFloat(shown.count) * lineHeight
            for row in shown {
                let text = Text(row).font(.system(size: fontSize, design: .monospaced)).foregroundColor(foreground.opacity(0.8))
                context.draw(text, at: CGPoint(x: 3, y: y), anchor: .topLeading)
                y += lineHeight
            }
        }
        .accessibilityHidden(true)
    }
}
