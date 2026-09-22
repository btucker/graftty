import AppKit
import SwiftUI

private struct WorktreeWindowColorKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}
extension EnvironmentValues {
    var worktreeWindowColor: Color? {
        get { self[WorktreeWindowColorKey.self] }
        set { self[WorktreeWindowColorKey.self] = newValue }
    }
}

/// A worktree's hue comes from its descriptor, never from the current row position.
@MainActor
struct WorktreeVisualColors {
    let title: Color
    let pane: Color

    init(image: NSImage, theme: GhosttyTheme, isActive: Bool = false) {
        let accent = NSColor(WorktreeArtworkPalette.colors(image)[0])
        let terrain = Self.terrain(image) ?? theme.backgroundNSColor
        let shaded = Self.mix(terrain, .black, amount: ArtworkBlockBacking.shadingOpacity)
        let background = isActive ? Self.mix(shaded, NSColor(theme.foreground), amount: 0.16) : shaded
        title = Color(nsColor: Self.readable(accent, on: background))
        pane = Color(nsColor: Self.readable(Self.mix(accent, NSColor(theme.foreground), amount: 0.5), on: background))
    }

    static func headerColor(image: NSImage, theme: GhosttyTheme) -> NSColor {
        mix(theme.backgroundNSColor, NSColor(WorktreeArtworkPalette.colors(image)[0]), amount: 0.36)
    }

    static func headerText(_ preferred: NSColor, on background: NSColor, opacity: Double = 1) -> NSColor {
        readable(mix(background, preferred, amount: opacity), on: background)
    }

    static func mix(_ a: NSColor, _ b: NSColor, amount: Double) -> NSColor {
        let a = a.usingColorSpace(.deviceRGB) ?? .black
        let b = b.usingColorSpace(.deviceRGB) ?? .white
        return NSColor(red: a.redComponent * (1-amount) + b.redComponent * amount,
            green: a.greenComponent * (1-amount) + b.greenComponent * amount,
            blue: a.blueComponent * (1-amount) + b.blueComponent * amount, alpha: 1)
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        func luminance(_ c: NSColor) -> Double {
            let c = c.usingColorSpace(.deviceRGB) ?? .black
            let linear = [c.redComponent, c.greenComponent, c.blueComponent].map {
                $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x,y) + 0.05) / (min(x,y) + 0.05)
    }

    static func readable(_ preferred: NSColor, on background: NSColor) -> NSColor {
        let anchor: NSColor = contrast(.white, background) > contrast(.black, background) ? .white : .black
        for step in 0...100 {
            let color = mix(preferred, anchor, amount: Double(step)/100)
            if contrast(color, background) >= 4.5 { return color }
        }
        return anchor
    }

    private static let terrainCache: NSCache<NSImage, NSColor> = {
        let cache = NSCache<NSImage, NSColor>()
        cache.countLimit = 128
        return cache
    }()

    private static func terrain(_ image: NSImage) -> NSColor? {
        if let cached = terrainCache.object(forKey: image) { return cached }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: cg)
        let color = bitmap.colorAt(x: min(cg.width-1, Int(Double(cg.width)*0.05)),
            y: min(cg.height-1, Int(Double(cg.height) * min(20, image.size.height/2) / image.size.height)))
        if let color { terrainCache.setObject(color, forKey: image) }
        return color
    }
}
