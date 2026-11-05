import SwiftUI
import GrafttyProtocol
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Renders the effective identity without storing a copy of the project's icon.
public struct WorktreeIdentityView: View {
    public let identity: WorktreeIconIdentity
    public let project: SidebarProject
    public var imageData: Data?
    public var size: CGFloat

    public init(identity: WorktreeIconIdentity, project: SidebarProject, imageData: Data? = nil, size: CGFloat = 28) {
        self.identity = identity; self.project = project; self.imageData = imageData; self.size = size
    }

    public var body: some View {
        Group {
            switch identity {
            case .project:
                ProjectIdentityView(project: project, imageData: imageData, size: size)
            case .drawing(_, let emoji):
                if let image = imageData.flatMap(DrawingImage.decode) {
                    image.resizable().scaledToFit().frame(width: size, height: size)
                } else if let emoji {
                    Text(emoji).font(.system(size: size * 0.8)).frame(width: size, height: size)
                }
            case .emoji(let emoji):
                Text(emoji).font(.system(size: size * 0.8)).frame(width: size, height: size)
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
        guard data.count <= 262_144 else { return nil }
        #if canImport(AppKit)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #elseif canImport(UIKit)
        return UIImage(data: data).map { Image(uiImage: $0) }
        #else
        return nil
        #endif
    }
}
