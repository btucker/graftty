import GrafttyProtocol
import SwiftUI

/// The shape of a worktree row on every platform: its identity beside the name
/// and status line, so both lines start at the same edge. Each platform supplies
/// the interactive parts.
public struct SidebarWorktreeRowLayout<Identity: View, Content: View>: View {
    public static var identitySize: CGFloat { 26 }

    private let identity: Identity
    private let content: Content

    public init(@ViewBuilder identity: () -> Identity, @ViewBuilder content: () -> Content) {
        self.identity = identity()
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            identity.frame(width: Self.identitySize, height: Self.identitySize + 6)
            VStack(alignment: .leading, spacing: 1) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A worktree's emoji or project image, faded when nothing is happening there.
public struct SidebarWorktreeRowIdentity: View {
    @Environment(\.colorScheme) private var colorScheme
    public let identity: WorktreeIconIdentity
    public let project: SidebarProject
    public var imageData: Data?
    public let status: SidebarRowStatus

    public init(identity: WorktreeIconIdentity, project: SidebarProject, imageData: Data? = nil, status: SidebarRowStatus) {
        self.identity = identity
        self.project = project
        self.imageData = imageData
        self.status = status
    }

    public var body: some View {
        WorktreeIdentityView(identity: identity, project: project, imageData: imageData,
                             size: SidebarWorktreeRowLayout<EmptyView, EmptyView>.identitySize)
            .opacity(status.identityOpacity(isDark: colorScheme == .dark))
    }
}

/// Names a part of a worktree list. Pinned can fold away.
public struct WorktreeListSectionTitle: View {
    @Environment(\.colorScheme) private var colorScheme
    public enum Tone { case attention, standard(Color) }

    private let title: String
    private let count: Int?
    private let tone: Tone
    private let isCollapsed: Binding<Bool>?

    public init(_ title: String, count: Int? = nil, tone: Tone, isCollapsed: Binding<Bool>? = nil) {
        self.title = title
        self.count = count
        self.tone = tone
        self.isCollapsed = isCollapsed
    }

    private var color: Color {
        switch tone {
        case .attention: return SidebarAttentionStyle.text(isDark: colorScheme == .dark)
        case .standard(let color): return color
        }
    }

    public var body: some View {
        Group {
            if let isCollapsed {
                Button { isCollapsed.wrappedValue.toggle() } label: {
                    HStack(spacing: 6) {
                        label
                        Spacer(minLength: 0)
                        Image(systemName: isCollapsed.wrappedValue ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
            } else {
                HStack { label; Spacer(minLength: 0) }
            }
        }
        .foregroundStyle(color)
        .padding(.top, 10)
        .padding(.horizontal, 8)
        .accessibilityAddTraits(.isHeader)
    }

    private var label: some View {
        Text(count.map { "\(title) · \($0)" } ?? title)
            .font(.footnote.weight(.semibold))
    }
}
