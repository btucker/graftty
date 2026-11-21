#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import GrafttyProtocol
import SwiftUI

/// @spec LAYOUT-2.192
/// While the selected worktree has an emoji, the application shall draw a blurred smear of it from the left and a fully visible tilted watermark of it toward the right, clear of the header's trailing controls, behind the window header and the top row of agent tabs, leaving emoji-less worktrees unchanged.
/// @spec LAYOUT-2.194
/// The main checkout draws its wash from the project icon, or from the
/// project's initials in its accent color when the project has no icon.
public struct WorktreeHeaderWash: Equatable {
    public enum Glyph: Equatable {
        case emoji(String)
        case image(Data)
        /// An agent drawing: transparent, with its own outline, so never clipped.
        case drawing(Data)
        case initials(String, Color)
    }

    public let glyph: Glyph
    public let background: Color
    public let isDark: Bool

    public init?(emoji: String?, background: Color, isDark: Bool) {
        self.init(identity: .resolve(isMainCheckout: false, emoji: emoji), project: nil, iconData: nil,
                  background: background, isDark: isDark)
    }

    /// Mirrors the breadcrumb's identity: the main checkout shows its project,
    /// linked worktrees their emoji, and identity-less worktrees nothing.
    public init?(identity: WorktreeIconIdentity, project: SidebarProject?, iconData: Data?, background: Color, isDark: Bool) {
        switch identity {
        case .emoji(let emoji) where !emoji.isEmpty:
            glyph = .emoji(emoji)
        case .drawing(_, let emoji):
            if let iconData, DrawingImage.decode(iconData) != nil {
                glyph = .drawing(iconData)
            } else if let emoji, !emoji.isEmpty {
                glyph = .emoji(emoji)
            } else {
                return nil
            }
        case .project:
            if let iconData, iconData.count <= 65536, PlatformImage.decode(iconData) != nil {
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

public struct WorktreeHeaderWashView: View {
    let wash: WorktreeHeaderWash
    /// Phones let the wash dissolve into the screen below the header.
    let fadesToBackground: Bool
    /// IOS-10.12: Low Power Mode throttles the GPU, so the blurred smear is
    /// left out and only the crisp watermark and gradient are drawn.
    let drawsSmear: Bool
    private let drawsWatermark: Bool
    /// Header text frames in this view's coordinates; the watermark is shaded beneath them.
    private let textFrames: [CGRect]

    public init(wash: WorktreeHeaderWash, fadesToBackground: Bool = false,
                isLowPower: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled, drawsWatermark: Bool = true,
                textFrames: [CGRect] = []) {
        self.wash = wash
        self.textFrames = textFrames
        self.fadesToBackground = fadesToBackground
        self.drawsSmear = !isLowPower
        self.drawsWatermark = drawsWatermark
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if drawsSmear {
                    WorktreeHeaderWashGlyph(glyph: wash.glyph, size: 420)
                        .scaleEffect(x: 2.4, y: 1, anchor: .leading)
                        .saturation(1.7)
                        .blur(radius: 44, opaque: false)
                        .opacity(wash.isDark ? 0.55 : 0.42)
                        .frame(height: proxy.size.height)
                        // Emoji glyphs carry side bearing; pull the smear left so
                        // its color reaches the header's leading edge.
                        .offset(x: wash.glyph.hasSideBearing ? -110 : -40)
                }
                LinearGradient(colors: [wash.background.opacity(0.18), wash.background.opacity(fadesToBackground ? 1 : 0.34)],
                               startPoint: .top, endPoint: .bottom)
                if drawsWatermark {
                    WorktreeHeaderWatermark(wash: wash)
                    if !textFrames.isEmpty {
                        WorktreeHeaderTextShade(frames: textFrames, color: wash.background)
                            .mask(WorktreeHeaderWatermark(wash: wash))
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
            .drawingGroup()
        }
    }

}

/// @spec LAYOUT-2.229
/// While the application draws a header watermark, it shall size the tilted icon to nearly twice the height of the header band, cropping it at the band's top and bottom edges, and show it at uniform opacity.
public struct WorktreeHeaderWatermark: View {
    private let wash: WorktreeHeaderWash
    private static let tilt = Angle.degrees(-12)

    public init(wash: WorktreeHeaderWash) { self.wash = wash }

    public var body: some View {
        GeometryReader { proxy in
            let inset = min(WorktreeHeaderWash.watermarkTrailingInset, proxy.size.width / 3)
            let rotationScale = abs(cos(Self.tilt.radians)) + abs(sin(Self.tilt.radians))
            // Nearly twice the band height, so the band crops the icon's top and bottom.
            let size = max(0, min(150, proxy.size.height * 1.9, (proxy.size.width - inset - 4) / rotationScale))
            if size > 0 {
                WorktreeHeaderWashGlyph(glyph: wash.glyph, size: wash.glyph.hasSideBearing ? size * 0.85 : size)
                    .frame(width: size, height: size)
                    .rotationEffect(Self.tilt)
                    .frame(width: size * rotationScale, height: proxy.size.height)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, inset)
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// @spec LAYOUT-2.244
/// While header text overlaps the header watermark, the application shall shade the watermark beneath that text, leaving the rest of the watermark and the header outside it unshaded.
/// Soft patches under header text; the caller masks them to the watermark.
private struct WorktreeHeaderTextShade: View {
    let frames: [CGRect]
    let color: Color

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                Capsule().fill(color.opacity(0.85))
                    .frame(width: frame.width + 12, height: frame.height + 4)
                    .offset(x: frame.minX - 6, y: frame.minY - 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .blur(radius: 4)
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
            if let image = PlatformImage.decode(data) {
                image.resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18))
            }
        case .drawing(let data):
            if let image = DrawingImage.decode(data) {
                image.resizable().scaledToFit().frame(width: size, height: size)
            }
        case .initials(let initials, let accent):
            Text(initials).font(.system(size: size * 0.62, weight: .bold)).foregroundStyle(accent)
                .frame(width: size, height: size)
                .background(accent.opacity(0.35), in: RoundedRectangle(cornerRadius: size * 0.18))
                .fixedSize()
        }
    }
}

enum PlatformImage {
    static func decode(_ data: Data) -> Image? { ProjectIconImage.image(data) }
}

extension WorktreeHeaderWash {
    /// How far the watermark sits in from the band's trailing edge.
    #if os(macOS)
    public static let watermarkTrailingInset: CGFloat = 150
    #else
    public static let watermarkTrailingInset: CGFloat = 12
    #endif

    /// Header surfaces draw slices of one band in this coordinate space, so
    /// the header and every top-row tab header line up seamlessly.
    public static let coordinateSpace = "worktreeHeaderWash"
}

/// One wash shared by several header surfaces.
public struct WorktreeHeaderWashBand: Equatable {
    public let wash: WorktreeHeaderWash
    public let size: CGSize
    /// Space above the coordinate origin the band also covers, such as a
    /// navigation bar the header extends beneath.
    public let topExtension: CGFloat
    /// Frames of header text in the band's coordinate space.
    public var textFrames: [CGRect] = []

    public init(wash: WorktreeHeaderWash, size: CGSize, topExtension: CGFloat = 0) {
        self.wash = wash
        self.size = size
        self.topExtension = topExtension
    }
}

private struct WorktreeHeaderWashBandKey: EnvironmentKey {
    static let defaultValue: WorktreeHeaderWashBand? = nil
}

extension EnvironmentValues {
    public var worktreeHeaderWashBand: WorktreeHeaderWashBand? {
        get { self[WorktreeHeaderWashBandKey.self] }
        set { self[WorktreeHeaderWashBandKey.self] = newValue }
    }
}

/// Header text frames reported to the band provider.
private struct WorktreeHeaderTextFramesKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

extension View {
    /// Provides one header wash band to the surfaces below, measured in the
    /// band's coordinate space, with the header text frames it shades.
    public func worktreeHeaderWashBand(_ band: WorktreeHeaderWashBand?) -> some View {
        modifier(WorktreeHeaderWashBandProvider(band: band))
    }

    /// Marks header text so the wash shades the watermark beneath it.
    public func worktreeHeaderWashText() -> some View {
        modifier(WorktreeHeaderWashTextFrame())
    }

    /// Overlays this surface's slice of the header band. Surfaces outside the
    /// band, such as tab headers of lower split panes, draw nothing.
    public func worktreeHeaderWash() -> some View {
        overlay { WorktreeHeaderWashSlice() }
    }
}

private struct WorktreeHeaderWashBandProvider: ViewModifier {
    let band: WorktreeHeaderWashBand?
    @State private var textFrames: [CGRect] = []

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(WorktreeHeaderTextFramesKey.self) { textFrames = $0 }
            .coordinateSpace(name: WorktreeHeaderWash.coordinateSpace)
            .environment(\.worktreeHeaderWashBand, band.map {
                var band = $0
                band.textFrames = textFrames
                return band
            })
    }
}

private struct WorktreeHeaderWashTextFrame: ViewModifier {
    @State private var frame: CGRect?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(WorktreeHeaderWash.coordinateSpace)) } action: { frame = $0 }
            .preference(key: WorktreeHeaderTextFramesKey.self, value: frame.map { [$0] } ?? [])
    }
}

private struct WorktreeHeaderWashSlice: View {
    @Environment(\.worktreeHeaderWashBand) private var band

    var body: some View {
        if let band {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .named(WorktreeHeaderWash.coordinateSpace)).origin
                if origin.y < band.size.height - band.topExtension {
                    WorktreeHeaderWashView(wash: band.wash, textFrames: band.textFrames.map {
                        $0.offsetBy(dx: 0, dy: band.topExtension)
                    })
                        .frame(width: band.size.width, height: band.size.height)
                        .offset(x: -origin.x, y: -origin.y - band.topExtension)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
