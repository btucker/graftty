import SwiftUI
import AppKit
import GhosttyKit

/// Keeps native terminal sizing independent from the pane while following.
struct SurfaceViewWrapper: NSViewRepresentable {
    let handle: SurfaceHandle

    func makeNSView(context: Context) -> MacFollowerTerminalView {
        let terminal = handle.view as! SurfaceNSView
        let view = MacFollowerTerminalView(
            terminalView: terminal,
            metrics: { [weak handle] in handle?.queryGridSize() ?? ghostty_surface_size_s() },
            makeHistorySurface: { [weak handle] view, scale in
                handle?.makeFollowerHistorySurface(in: view, scale: scale)
            }
        )
        handle.followerPresentation = view
        view.followerGrid = handle.followerDisplayGrid
        view.updateScrollbar(handle.followerScrollbar)
        return view
    }

    func updateNSView(_ view: MacFollowerTerminalView, context: Context) {
        view.followerGrid = handle.followerDisplayGrid
        view.needsLayout = true
    }
}
