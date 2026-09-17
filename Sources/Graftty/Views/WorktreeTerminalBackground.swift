import SwiftUI

/// Shared by the whole split layout so dividers never restart the image or fade.
struct WorktreeTerminalBackground: View {
    let image: NSImage
    let backgroundColor: Color

    var isRegenerating = false

    var body: some View {
        GeometryReader { geometry in
            backgroundColor
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: isRegenerating ? 12 : 0)
                        .opacity(isRegenerating ? 0.55 : 1)
                        .mask {
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.36), location: 0),
                                    .init(color: .white.opacity(0.22), location: 0.2),
                                    .init(color: .clear, location: 0.5),
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
