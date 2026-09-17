import SwiftUI

/// Owns artwork in window coordinates, outside the navigation columns.
struct WorktreeWindowArtwork: ViewModifier {
    let image: NSImage?
    let backgroundColor: Color
    var isRegenerating = false

    func body(content: Content) -> some View {
        content.background {
            if let image {
                WorktreeTerminalBackground(image: image, backgroundColor: backgroundColor,
                                          isRegenerating: isRegenerating)
                    .ignoresSafeArea()
            }
        }
    }
}
