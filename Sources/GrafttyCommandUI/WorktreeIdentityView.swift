import SwiftUI
import GrafttyProtocol

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
            case .emoji(let emoji):
                Text(emoji).font(.system(size: size * 0.8)).frame(width: size, height: size)
            case .none:
                EmptyView()
            }
        }
        .accessibilityHidden(true)
    }
}
