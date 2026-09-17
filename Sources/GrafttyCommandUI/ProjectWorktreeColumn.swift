import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Uses the project rail's margins without native List disclosure-column padding.
public struct ProjectWorktreeColumn<Content: View>: View {
    private let content: Content
    private let onDoubleClickEmptySpace: () -> Void
    @State private var rowsHeight: CGFloat = 0

    public init(onDoubleClickEmptySpace: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.onDoubleClickEmptySpace = onDoubleClickEmptySpace
        self.content = content()
    }

    public var body: some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        content
                    }
                    .padding(.horizontal, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }

                    #if os(macOS)
                    ProjectWorktreeEmptySpace(onDoubleClick: onDoubleClickEmptySpace)
                        .frame(height: max(0, viewport.size.height - rowsHeight))
                    #else
                    Color.clear.frame(height: max(0, viewport.size.height - rowsHeight))
                    #endif
                }
            }
        }
    }
}

#if os(macOS)
private struct ProjectWorktreeEmptySpace: NSViewRepresentable {
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> ProjectWorktreeEmptySpaceView {
        let view = ProjectWorktreeEmptySpaceView()
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: ProjectWorktreeEmptySpaceView, context: Context) {
        view.onDoubleClick = onDoubleClick
    }
}

final class ProjectWorktreeEmptySpaceView: NSView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }
}
#endif
