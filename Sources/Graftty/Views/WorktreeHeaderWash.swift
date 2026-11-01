import AppKit
import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

/// @spec LAYOUT-2.192
/// The selected worktree's emoji, drawn behind the window header and the top
/// row of agent tabs: a blurred smear from the left and a tilted watermark on
/// the right. Worktrees without an emoji keep the plain header.
/// @spec LAYOUT-2.194
/// The main checkout draws its wash from the project icon, or from the
/// project's initials in its accent color when the project has no icon.
struct WorktreeHeaderWash: Equatable {
    enum Glyph: Equatable {
        case emoji(String)
        case image(Data)
        case initials(String, Color)
    }

    let glyph: Glyph
    let background: Color
    let isDark: Bool

    /// Header surfaces draw slices of one band in this coordinate space, so
    /// the breadcrumb and every top-row tab header line up seamlessly.
    static let coordinateSpace = "worktreeHeaderWash"
    /// The tab row below the breadcrumb is part of the band.
    static let tabRowHeight: CGFloat = 36

    init?(emoji: String?, background: Color, isDark: Bool) {
        self.init(identity: .resolve(isMainCheckout: false, emoji: emoji), project: nil, iconData: nil,
                  background: background, isDark: isDark)
    }

    /// Mirrors the breadcrumb's identity: the main checkout shows its project,
    /// linked worktrees their emoji, and identity-less worktrees nothing.
    init?(identity: WorktreeIconIdentity, project: SidebarProject?, iconData: Data?, background: Color, isDark: Bool) {
        switch identity {
        case .emoji(let emoji) where !emoji.isEmpty:
            glyph = .emoji(emoji)
        case .project:
            if let iconData, iconData.count <= 65536, NSImage(data: iconData) != nil {
                glyph = .image(iconData)
            } else if let project {
                glyph = .initials(project.displayInitials, ProjectAccentColor.color(for: project))
            } else {
                return nil
            }
        default:
            return nil
        }
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
                WorktreeHeaderWashGlyph(glyph: wash.glyph, size: 420)
                    .scaleEffect(x: 2.4, y: 1, anchor: .leading)
                    .saturation(1.7)
                    .blur(radius: 44, opaque: false)
                    .opacity(wash.isDark ? 0.55 : 0.42)
                    .frame(height: proxy.size.height)
                    // Emoji glyphs carry side bearing; pull the smear left so
                    // its color reaches the header's leading edge.
                    .offset(x: wash.glyph.hasSideBearing ? -110 : -40)
                watermarkLayer
                    .rotationEffect(.degrees(-12))
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

    /// A crisp mark reads as intentional; a light blur reads as a low-resolution
    /// image. It dissolves leftward into the smear instead.
    private var watermarkLayer: some View {
        WorktreeHeaderWashGlyph(glyph: wash.glyph, size: 114)
            .opacity(wash.isDark ? 0.62 : 0.52)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.65)],
                                 startPoint: .leading, endPoint: .trailing))
    }
}

extension WorktreeHeaderWash.Glyph {
    var hasSideBearing: Bool {
        if case .emoji = self { return true }
        return false
    }
}

/// One copy of the identity glyph at a given visual size.
private struct WorktreeHeaderWashGlyph: View {
    let glyph: WorktreeHeaderWash.Glyph
    let size: CGFloat

    var body: some View {
        switch glyph {
        case .emoji(let emoji):
            Text(emoji).font(.system(size: size)).fixedSize()
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
            }
        case .initials(let initials, let accent):
            Text(initials).font(.system(size: size * 0.62, weight: .bold)).foregroundStyle(accent)
                .frame(width: size, height: size)
                .background(accent.opacity(0.35), in: RoundedRectangle(cornerRadius: size * 0.18))
                .fixedSize()
        }
    }
}
