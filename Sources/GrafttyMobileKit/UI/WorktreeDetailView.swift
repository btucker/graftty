#if canImport(UIKit)
import GhosttyTerminal
import GrafttyProtocol
import SwiftUI

/// Second "inside a host" screen — shows the split-faithful tree of
/// panes for the selected worktree. Tapping a pane tile pushes a
/// `SessionStep` onto the navigation stack which opens that pane's
/// terminal fullscreen.
public struct WorktreeDetailView: View {
    public let host: Host
    public let worktree: WorktreePanes
    public let onSelectPane: (_ sessionName: String) -> Void

    @State private var controller: TerminalController?
    @State private var previews: PanePreviewClientPool<SessionClient>?

    public init(
        host: Host,
        worktree: WorktreePanes,
        onSelectPane: @escaping (_ sessionName: String) -> Void
    ) {
        self.host = host
        self.worktree = worktree
        self.onSelectPane = onSelectPane
    }

    public var body: some View {
        Group {
            if let layout = worktree.layout {
                PaneLayoutView(
                    layout: layout,
                    controller: controller,
                    previewClient: { previews?.clients[$0] }
                ) { sessionName in
                    onSelectPane(sessionName)
                }
            } else {
                ContentUnavailableView(
                    "No panes running",
                    systemImage: "terminal",
                    description: Text("Start a pane in Graftty on the Mac to see it here.")
                )
            }
        }
        .navigationTitle(worktree.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: host.id) {
            if controller == nil {
                let text = await GhosttyConfigFetcher.fetch(baseURL: host.baseURL)
                controller = TerminalController(
                    configSource: text.map { .generated($0) } ?? .none
                )
            }
        }
        .task(id: worktree.layout) {
            guard let layout = worktree.layout else { return }
            if previews == nil {
                previews = PanePreviewClientPool { sessionName in
                    let wsURL = RootView.makeWebSocketURL(base: host.baseURL, session: sessionName)
                    let ws = URLSessionWebSocketClient(url: wsURL)
                    return SessionClient(sessionName: sessionName, webSocket: ws)
                }
            }
            previews?.update(layout: layout)
        }
        .onDisappear {
            previews?.stopAll()
        }
    }
}
#endif
