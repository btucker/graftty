#if canImport(UIKit)
import GhosttyTerminal
import SwiftUI

public struct SplitContainerView: View {
    public let panes: [HostController.Pane]
    public let sessionFor: (UUID) -> InMemoryTerminalSession?

    public init(
        panes: [HostController.Pane],
        sessionFor: @escaping (UUID) -> InMemoryTerminalSession?
    ) {
        self.panes = panes
        self.sessionFor = sessionFor
    }

    public var body: some View {
        if panes.isEmpty {
            ContentUnavailableView("No pane selected", systemImage: "terminal")
        } else if panes.count == 1, let session = sessionFor(panes[0].id) {
            TerminalPaneView(session: session)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(panes.prefix(2).enumerated()), id: \.element.id) { index, pane in
                    if let session = sessionFor(pane.id) {
                        TerminalPaneView(session: session)
                    } else {
                        Color.clear
                    }
                    if index == 0 && panes.count >= 2 {
                        Divider()
                    }
                }
            }
        }
    }
}
#endif
