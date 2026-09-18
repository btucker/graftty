import AppKit
import SwiftUI

/// One decorative image behind the entire worktree block, including its panes.
struct WorktreeArtworkBackground: View {
    let image: NSImage
    let backgroundColor: Color
    let selectionColor: Color

    var isRegenerating = false
    var fadesBottom = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func resolveImage(isMainCheckout: Bool, projectIcon: Data?, generated: NSImage?) -> NSImage? {
        if isMainCheckout { return generated ?? projectIcon.flatMap { NSImage(data: $0) } }
        return generated
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: image.size.width, height: image.size.height)
                .blur(radius: isRegenerating ? 12 : 0)
                .opacity(isRegenerating ? 0.55 : 1)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.8),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.85),
                        .init(color: fadesBottom || geometry.size.height > image.size.height ? .clear : .white, location: 1),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(backgroundColor)
                .overlay(selectionColor)
                .clipped()
                .id(ObjectIdentifier(image))
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: ObjectIdentifier(image))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
