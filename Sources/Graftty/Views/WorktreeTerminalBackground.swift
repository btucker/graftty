import SwiftUI

/// A single smooth gradient behind the window; raster detail stays in the sidebar.
struct WorktreeTerminalBackground: View {
    let image: NSImage
    let backgroundColor: Color

    var isRegenerating = false

    var body: some View {
        GeometryReader { geometry in
            backgroundColor
                .overlay {
                    LinearGradient(colors: WorktreeArtworkPalette.colors(image), startPoint: .topLeading, endPoint: .topTrailing)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .opacity(isRegenerating ? 0.55 : 1)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.36), location: 0),
                                    .init(color: .white.opacity(0.22), location: 0.2),
                                    .init(color: .clear, location: 0.75),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        }
                }
                .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
