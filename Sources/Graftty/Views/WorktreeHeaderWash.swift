import SwiftUI

/// @spec LAYOUT-2.192
/// The selected worktree's emoji, drawn behind the window header and the top
/// row of agent tabs: a blurred smear from the left and a tilted watermark on
/// the right. Worktrees without an emoji keep the plain header.
struct WorktreeHeaderWash: Equatable {
    let emoji: String
    let background: Color
    let isDark: Bool

    /// Header surfaces draw slices of one band in this coordinate space, so
    /// the breadcrumb and every top-row tab header line up seamlessly.
    static let coordinateSpace = "worktreeHeaderWash"
    /// The tab row below the breadcrumb is part of the band.
    static let tabRowHeight: CGFloat = 36

    init?(emoji: String?, background: Color, isDark: Bool) {
        guard let emoji, !emoji.isEmpty else { return nil }
        self.emoji = emoji
        self.background = background
        self.isDark = isDark
    }
}

struct WorktreeHeaderWashBand: Equatable {
    let wash: WorktreeHeaderWash
    let size: CGSize
}

private struct WorktreeHeaderWashBandKey: EnvironmentKey {
    static let defaultValue: WorktreeHeaderWashBand? = nil
}

extension EnvironmentValues {
    var worktreeHeaderWashBand: WorktreeHeaderWashBand? {
        get { self[WorktreeHeaderWashBandKey.self] }
        set { self[WorktreeHeaderWashBandKey.self] = newValue }
    }
}

extension View {
    /// Overlays this surface's slice of the header band. Surfaces outside the
    /// band, such as tab headers of lower split panes, draw nothing.
    func worktreeHeaderWash() -> some View {
        overlay { WorktreeHeaderWashSlice() }
    }
}

private struct WorktreeHeaderWashSlice: View {
    @Environment(\.worktreeHeaderWashBand) private var band

    var body: some View {
        if let band {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .named(WorktreeHeaderWash.coordinateSpace)).origin
                if origin.y < band.size.height {
                    WorktreeHeaderWashView(wash: band.wash)
                        .frame(width: band.size.width, height: band.size.height)
                        .offset(x: -origin.x, y: -origin.y)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

struct WorktreeHeaderWashView: View {
    let wash: WorktreeHeaderWash

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Text(wash.emoji)
                    .font(.system(size: 420))
                    .fixedSize()
                    .scaleEffect(x: 2.4, y: 1, anchor: .leading)
                    .saturation(1.7)
                    .blur(radius: 44, opaque: false)
                    .opacity(wash.isDark ? 0.55 : 0.42)
                    .frame(height: proxy.size.height)
                    // Emoji glyphs carry side bearing; pull the smear left so
                    // its color reaches the header's leading edge.
                    .offset(x: -110)
                Text(wash.emoji)
                    .font(.system(size: 114))
                    .fixedSize()
                    .blur(radius: 2.5)
                    .rotationEffect(.degrees(-12))
                    .opacity(wash.isDark ? 0.6 : 0.5)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .trailing)
                    .offset(x: 34)
                LinearGradient(colors: [wash.background.opacity(0.18), wash.background.opacity(0.34)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .drawingGroup()
        }
    }
}
