import AppKit
import SwiftUI

/// One decorative image behind the entire worktree block, including its panes.
struct WorktreeArtworkBackground: View {
    let image: NSImage
    let backgroundColor: Color
    let selectionColor: Color

    var isRegenerating = false

    static func resolveImage(isMainCheckout: Bool, projectIcon: Data?, generated: NSImage?) -> NSImage? {
        if isMainCheckout { return projectIcon.flatMap { NSImage(data: $0) } }
        return generated
    }

    var body: some View {
        GeometryReader { geometry in
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: geometry.size.width, height: geometry.size.height)
                .blur(radius: isRegenerating ? 12 : 0)
                .opacity(isRegenerating ? 0.55 : 1)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: backgroundColor.opacity(0.90), location: 0),
                            .init(color: backgroundColor.opacity(0.75), location: 0.55),
                            .init(color: backgroundColor.opacity(0.35), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .overlay(selectionColor)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
