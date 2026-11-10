import SwiftUI
import GrafttyProtocol

/// Renders the effective identity without storing a copy of the project's icon.
public struct WorktreeIdentityView: View {
    public let identity: WorktreeIconIdentity
    public let project: SidebarProject
    public var imageData: Data?
    /// The height. A drawing keeps its shape, so a wide one is wider than this.
    public var size: CGFloat
    /// The most width a drawing may take; nil lets it take its natural width.
    public var maxWidth: CGFloat?
    /// Emoji and project icons stop growing here, so a large slot made for
    /// wide drawings doesn't blow them up.
    public static let maxGlyphSize: CGFloat = 32

    public init(identity: WorktreeIconIdentity, project: SidebarProject, imageData: Data? = nil, size: CGFloat = 28,
                maxWidth: CGFloat? = nil) {
        self.identity = identity; self.project = project; self.imageData = imageData; self.size = size; self.maxWidth = maxWidth
    }

    private var glyph: CGFloat { min(size, Self.maxGlyphSize) }

    public var body: some View {
        Group {
            switch identity {
            case .project:
                ProjectIdentityView(project: project, imageData: imageData, size: glyph)
            case .drawing(_, let emoji):
                if let image = imageData.flatMap(DrawingImage.decode) {
                    image.resizable().scaledToFit().frame(height: size).frame(maxWidth: maxWidth)
                } else if let emoji {
                    Text(emoji).font(.system(size: glyph * 0.8)).frame(width: glyph, height: glyph)
                }
            case .emoji(let emoji):
                Text(emoji).font(.system(size: glyph * 0.8)).frame(width: glyph, height: glyph)
            case .none:
                EmptyView()
            }
        }
        .accessibilityHidden(true)
    }
}

/// @spec LAYOUT-2.202
/// Decodes a rendered worktree drawing for display at identity size.
enum DrawingImage {
    static func decode(_ data: Data) -> Image? {
        data.count <= WorktreeDrawingCache.maxBytes ? PlatformImage.decode(data) : nil
    }
}
