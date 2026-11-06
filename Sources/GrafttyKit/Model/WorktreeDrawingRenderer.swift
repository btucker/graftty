#if canImport(AppKit)
import AppKit
import Foundation

/// @spec LAYOUT-2.201
/// Turns a validated drawing into the PNG every client shows. Clients never
/// parse agent SVG; they receive pixels rendered here with the worktree's
/// palette and a white outline that separates the drawing from dark headers.
public enum WorktreeDrawingRenderer {
    public static let pixels = 256
    public static let maxPNGBytes = 262_144
    private static let cache = NSCache<NSString, NSData>()
    /// Agents often single-quote attributes so the SVG fits in recap JSON.
    private static let paintToken = try? NSRegularExpression(pattern: #"(fill|stroke|stop-color)=(["'])([a-z-]+)\2"#)

    /// Palette tokens as sRGB hex. The accent is the primary hue rotated 40°.
    public static func palette(hue: Double) -> [String: String] {
        let accent = (hue + 40).truncatingRemainder(dividingBy: 360)
        return [
            "primary": hex(oklch: (0.60, 0.15, hue)),
            "primary-light": hex(oklch: (0.88, 0.06, hue)),
            "primary-dark": hex(oklch: (0.42, 0.12, hue)),
            "accent": hex(oklch: (0.74, 0.16, accent)),
            "accent-light": hex(oklch: (0.90, 0.08, accent)),
            "ink": "#24242c",
            "white": "#ffffff",
            "none": "none",
        ]
    }

    public static func png(svg: String, hue: Double, pixels: Int = pixels) -> Data? {
        let colors = palette(hue: hue)
        let range = NSRange(svg.startIndex..., in: svg)
        var filled = svg
        for match in (paintToken?.matches(in: svg, range: range) ?? []).reversed() {
            guard let attribute = Range(match.range(at: 1), in: svg), let token = Range(match.range(at: 3), in: svg),
                  let color = colors[String(svg[token])], let whole = Range(match.range, in: filled) else { continue }
            filled.replaceSubrange(whole, with: "\(svg[attribute])=\"\(color)\"")
        }
        guard let image = NSImage(data: Data(filled.utf8)), let shape = bitmap(pixels, { context in
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        }), let outlined = bitmap(pixels, { context in
            let full = CGRect(x: 0, y: 0, width: pixels, height: pixels)
            let radius = Double(pixels) / 36
            for step in 0..<16 {
                let angle = Double(step) * .pi / 8
                context.draw(shape, in: full.offsetBy(dx: cos(angle) * radius, dy: sin(angle) * radius))
            }
            context.setBlendMode(.sourceIn)
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(full)
            context.setBlendMode(.normal)
            context.draw(shape, in: full)
        }) else { return nil }
        let data = NSBitmapImageRep(cgImage: outlined).representation(using: .png, properties: [:])
        return data.flatMap { $0.count <= maxPNGBytes ? $0 : nil }
    }

    /// The PNG for a host's current drawing, or nil for a stale revision.
    public static func iconResponse(for repos: [RepoEntry], worktreeID: String, revision: String) -> Data? {
        for repo in repos where repo.path != worktreeID {
            guard let worktree = repo.worktrees.first(where: { $0.path == worktreeID }),
                  let drawing = worktree.drawing, drawing.revision == revision, let hue = worktree.drawingHue else { continue }
            return png(for: drawing, hue: hue)
        }
        return nil
    }

    /// Renders each revision once. A failed render is remembered as empty, so
    /// a drawing the renderer rejects is not re-rendered on every request.
    public static func png(for drawing: WorktreeDrawing, hue: Double) -> Data? {
        let key = drawing.revision as NSString
        if let cached = cache.object(forKey: key) { return cached.length > 0 ? cached as Data : nil }
        let data = png(svg: drawing.svg, hue: hue)
        cache.setObject((data ?? Data()) as NSData, forKey: key)
        return data
    }

    /// The chroma-weighted OKLCH hue of an image, or nil for a gray image.
    public static func dominantHue(ofImage data: Data) -> Double? {
        guard let image = NSBitmapImageRep(data: data)?.cgImage else { return nil }
        let side = 32
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sumA = 0.0, sumB = 0.0, weight = 0.0
        for offset in stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
            let alpha = Double(bytes[offset + 3]) / 255
            let (a, b) = oklab(red: Double(bytes[offset]) / 255 / alpha, green: Double(bytes[offset + 1]) / 255 / alpha,
                               blue: Double(bytes[offset + 2]) / 255 / alpha)
            let chroma = (a * a + b * b).squareRoot()
            guard chroma > 0.04 else { continue }
            sumA += a * alpha; sumB += b * alpha; weight += alpha
        }
        guard weight > 0 else { return nil }
        let hue = atan2(sumB, sumA) * 180 / .pi
        return hue < 0 ? hue + 360 : hue
    }

    private static func bitmap(_ side: Int, _ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    private static func hex(oklch: (lightness: Double, chroma: Double, hue: Double)) -> String {
        let radians = oklch.hue * .pi / 180
        let a = oklch.chroma * cos(radians), b = oklch.chroma * sin(radians)
        let l = pow(oklch.lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(oklch.lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(oklch.lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let linear = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
        return "#" + linear.map { value -> String in
            let clamped = min(max(value, 0), 1)
            let encoded = clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055
            return String(format: "%02x", Int((encoded * 255).rounded()))
        }.joined()
    }

    private static func oklab(red: Double, green: Double, blue: Double) -> (a: Double, b: Double) {
        func linear(_ value: Double) -> Double {
            let v = min(max(value, 0), 1)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let (r, g, b) = (linear(red), linear(green), linear(blue))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }
}
#endif
