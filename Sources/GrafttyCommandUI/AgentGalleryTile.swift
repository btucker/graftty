import SwiftUI

/// One agent in the gallery: a live miniature of its terminal, a two-line
/// caption, and its scroll rail on the right edge, so a tile follows the same
/// rule as the stage (a terminal, then its rail).
public struct AgentGalleryTile<Thumbnail: View, Rail: View>: View {
    public static var railWidth: CGFloat { 16 }
    public static var cornerRadius: CGFloat { 6 }

    let title: String
    let status: AgentTileStatus
    let isOnStage: Bool
    let foreground: Color
    let background: Color
    let thumbnail: Thumbnail
    let rail: Rail
    let decorateBody: (AnyView) -> AnyView

    /// `decorateBody` wraps the thumbnail and caption, not the rail, so a
    /// click or drag on the tile never competes with the rail's own pointer input.
    public init(title: String, status: AgentTileStatus, isOnStage: Bool, foreground: Color, background: Color,
                decorateBody: @escaping (AnyView) -> AnyView = { $0 },
                @ViewBuilder thumbnail: () -> Thumbnail, @ViewBuilder rail: () -> Rail) {
        self.title = title; self.status = status; self.isOnStage = isOnStage
        self.foreground = foreground; self.background = background
        self.decorateBody = decorateBody
        self.thumbnail = thumbnail(); self.rail = rail()
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous) }

    public var body: some View {
        HStack(spacing: 0) {
            decorateBody(AnyView(tileBody))
            // Not clipped: the rail's preview cards spill over the tile and the stage.
            rail
                .frame(width: Self.railWidth)
                .frame(maxHeight: .infinity)
                .background(foreground.opacity(0.03))
                .overlay(alignment: .leading) { foreground.opacity(0.1).frame(width: 1) }
                .zIndex(1)
        }
        .background(background, in: shape)
        .overlay {
            shape.strokeBorder(foreground.opacity(isOnStage ? 0.7 : 0.12), lineWidth: isOnStage ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isOnStage ? [.isButton, .isSelected] : .isButton)
    }

    private var tileBody: some View {
            VStack(alignment: .leading, spacing: 0) {
                thumbnail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .opacity(status.isDimmed ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
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

/// The last tile in every gallery, for starting another agent in the worktree.
public struct AgentGalleryEmptyTile: View {
    let foreground: Color

    public init(foreground: Color) { self.foreground = foreground }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: AgentGalleryTile<EmptyView, EmptyView>.cornerRadius, style: .continuous)
        Label("New agent", systemImage: "plus")
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
