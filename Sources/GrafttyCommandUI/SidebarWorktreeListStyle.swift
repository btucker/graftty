import SwiftUI

/// Project navigation owns the outer hierarchy; the adjacent list only indents folders.
public struct SidebarWorktreeListStyle: ViewModifier {
    public static var projectRowInsets: EdgeInsets {
        #if os(macOS)
        // AppKit adds 8 points outside each cell's custom inset. Offset that
        // padding so the highlight starts 6 points from the column edge.
        EdgeInsets(top: 1.5, leading: -2, bottom: 1.5, trailing: -2)
        #else
        EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        #endif
    }

    public let projectColumn: Bool

    public init(projectColumn: Bool) { self.projectColumn = projectColumn }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if projectColumn {
            content.listStyle(.plain)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .scrollContentBackground(.hidden)
                #if !os(macOS)
                .listRowSpacing(3)
                #endif
                .environment(\.defaultMinListRowHeight, 44)
        } else {
            content.listStyle(.sidebar)
        }
    }
}
