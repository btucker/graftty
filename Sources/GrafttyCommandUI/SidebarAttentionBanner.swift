import SwiftUI
import GrafttyProtocol

public struct SidebarAttentionBanner: View {
    public let item: SidebarActivityItem
    public var project: SidebarProject?
    public var projectIconData: Data?
    public var onOpen: () -> Void
    public var onDismiss: () -> Void
    @State private var isHovered = false

    public init(item: SidebarActivityItem, project: SidebarProject? = nil, projectIconData: Data? = nil, onOpen: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.item = item
        self.project = project
        self.projectIconData = projectIconData
        self.onOpen = onOpen
        self.onDismiss = onDismiss
    }

    private var requestText: String {
        item.agentStop?.recap?.need ?? item.agentStop?.recap?.title ?? item.title
    }

    var identityView: WorktreeIdentityView {
        WorktreeIdentityView(identity: item.iconIdentity,
            project: project ?? SidebarProject(id: item.projectID, repositoryID: item.projectID, name: item.projectName),
            imageData: projectIconData, size: 22)
    }

    public var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    identityView
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.worktreeName).font(.caption).fontWeight(.semibold).lineLimit(1)
                        Text(requestText)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(requestText)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Attention for \(item.worktreeName)")
            .accessibilityValue(requestText)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2).foregroundStyle(.secondary)
                    .frame(width: 22, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Hide notification")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(.orange).frame(width: 3).padding(.vertical, 8)
        }
        .onHover { isHovered = $0 }
        .task(id: TimerIdentity(id: item.id, occurrence: item.occurrence, hovered: isHovered)) {
            guard !isHovered else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            onDismiss()
        }
    }

    private struct TimerIdentity: Hashable {
        let id: String
        let occurrence: SidebarAttentionOccurrence?
        let hovered: Bool
    }
}
