import SwiftUI

/// Uses the project rail's margins without native List disclosure-column padding.
public struct ProjectWorktreeColumn<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                content
            }.padding(.horizontal, 6)
        }
    }
}
