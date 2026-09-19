import AppKit
import SwiftUI

struct ProjectMapHeaderAvatar: View {
    let image: NSImage
    let backgroundColor: Color
    let projectName: String

    var body: some View {
        Image(nsImage: image).resizable().scaledToFit()
            .frame(width: 36, height: 36).padding(5)
            .background(backgroundColor.opacity(0.9), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityLabel(projectName)
    }
}

/// One decorative image behind the entire worktree block, including its panes.
struct WorktreeArtworkBackground: View {
    let image: NSImage
    let backgroundColor: Color
    let selectionColor: Color

    var isRegenerating = false
    var fadesBottom = false
    var groupsText = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func resolveImage(isMainCheckout: Bool, projectIcon: Data?, generated: NSImage?) -> NSImage? {
        // Avatars guide generation, but are not map-sized loading placeholders.
        return generated
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Group {
                    if groupsText { WorktreeMapArtwork(image: image) }
                    else { Image(nsImage: image).resizable().interpolation(.high) }
                }
                .frame(width: image.size.width, height: image.size.height)
                .blur(radius: isRegenerating ? 12 : 0)
                .opacity(isRegenerating ? 0.55 : 1)
                .overlay { if groupsText { ArtworkBlockBacking() } }
                .overlay(selectionColor)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .white, location: 0),
                            .init(color: .white, location: 0.8),
                            .init(color: .white.opacity(WorktreeMapLayout.trailingOpacity(availableWidth: geometry.size.width, imageWidth: image.size.width)), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                }
                .mask {
                    LinearGradient(stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: 0.85),
                        .init(color: fadesBottom || geometry.size.height > image.size.height ? .clear : .white, location: 0.98),
                    ], startPoint: .top, endPoint: .bottom)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(backgroundColor)
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

/// A terrain-only map section reaches behind search and window chrome.
/// Only this decorative section fits the header height; landmarks keep their scale.
struct WorktreeMapHeaderBackground: View {
    let image: NSImage
    let backgroundColor: Color

    var body: some View {
        GeometryReader { geometry in
            WorktreeMapArtwork(image: image, decorative: true)
                .frame(width: WorktreeMapLayout.width, height: geometry.size.height)
                .overlay(.black.opacity(0.14))
                .mask {
                    LinearGradient(stops: [.init(color: .white, location: 0.8),
                                           .init(color: .white.opacity(WorktreeMapLayout.trailingOpacity(availableWidth: geometry.size.width)), location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .background(backgroundColor)
                .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
