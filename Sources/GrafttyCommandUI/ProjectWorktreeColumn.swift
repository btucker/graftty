import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Uses the project rail's margins without native List disclosure-column padding.
public struct ProjectWorktreeColumn<Content: View, Header: View>: View {
    private let content: Content
    private let header: Header
    private let onDoubleClickEmptySpace: () -> Void
    #if os(macOS)
    private var emptySpaceMenu: (() -> NSMenu)?
    #endif
    @State private var rowsHeight: CGFloat = 0

    public init(onDoubleClickEmptySpace: @escaping () -> Void = {},
                @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.onDoubleClickEmptySpace = onDoubleClickEmptySpace
        self.content = content()
        self.header = header()
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { viewport in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            content
                        }
                        .padding(.horizontal, 6)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }

                        #if os(macOS)
                        ProjectWorktreeEmptySpace(onDoubleClick: onDoubleClickEmptySpace, menu: emptySpaceMenu)
                            .frame(height: max(0, viewport.size.height - rowsHeight))
                        #else
                        Color.clear.frame(height: max(0, viewport.size.height - rowsHeight))
                        #endif
                    }
                }
            }
        }
    }
}

#if os(macOS)
extension ProjectWorktreeColumn {
    /// Menu shown on right-click below the last row (LAYOUT-2.95).
    public func emptySpaceMenu(_ build: @escaping () -> NSMenu) -> Self {
        var copy = self
        copy.emptySpaceMenu = build
        return copy
    }
}
#endif

extension ProjectWorktreeColumn where Header == EmptyView {
    public init(onDoubleClickEmptySpace: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.init(onDoubleClickEmptySpace: onDoubleClickEmptySpace, header: { EmptyView() }, content: content)
    }
}

#if os(macOS)
private struct ProjectWorktreeEmptySpace: NSViewRepresentable {
    let onDoubleClick: () -> Void
    let menu: (() -> NSMenu)?

    func makeNSView(context: Context) -> ProjectWorktreeEmptySpaceView {
        let view = ProjectWorktreeEmptySpaceView()
        view.onDoubleClick = onDoubleClick
        view.menuBuilder = menu
        return view
    }

    func updateNSView(_ view: ProjectWorktreeEmptySpaceView, context: Context) {
        view.onDoubleClick = onDoubleClick
        view.menuBuilder = menu
    }
}

final class ProjectWorktreeEmptySpaceView: NSView {
    var onDoubleClick: (() -> Void)?
    var menuBuilder: (() -> NSMenu)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let menu = menuBuilder?(), !menu.items.isEmpty else { return nil }
        return menu
    }
}
#endif
