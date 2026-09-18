import SwiftUI

/// Repeats only the map's decorative footer, keeping worktree sections at their original scale.
struct WorktreeMapTailBackground: View {
    let image: NSImage
    let backgroundColor: Color

    var body: some View {
        GeometryReader { geometry in
            let tileHeight = max(1, image.size.height)
            let count = max(1, Int(ceil(geometry.size.height / tileHeight)))
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    Image(nsImage: image)
                        .resizable().interpolation(.high)
                        .frame(width: WorktreeMapLayout.width, height: tileHeight)
                        // Mirrored repeats meet at identical edge pixels, even
                        // when the provider's texture is not perfectly tileable.
                        .scaleEffect(x: 1, y: index.isMultiple(of: 2) ? 1 : -1)
                }
            }
            .overlay { ArtworkBlockBacking(showsSeparator: false) }
            .mask {
                LinearGradient(stops: [.init(color: .white, location: 0.8),
                                       .init(color: .white.opacity(WorktreeMapLayout.trailingOpacity(availableWidth: geometry.size.width)), location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .background(backgroundColor)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
