import AppKit
import SwiftUI
import Testing
@testable import Graftty

@MainActor
struct WorktreeHeaderWashTests {
    private static let background = Color(red: 0.11, green: 0.12, blue: 0.14)

    /// The real header composition: breadcrumb above, then a workspace whose
    /// top row starts with a tab header and continues with terminal content.
    private struct Fixture: View {
        let wash: WorktreeHeaderWash?
        var body: some View {
            MainWindowDetailLayout(headerWash: wash) {
                Color.clear.frame(height: 40)
                    .background { WorktreeHeaderWashTests.background.worktreeHeaderWash() }
            } content: {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 36)
                        .background { WorktreeHeaderWashTests.background.worktreeHeaderWash() }
                    WorktreeHeaderWashTests.background
                }
            }
            .frame(width: 900, height: 300)
        }
    }

    private struct Pixel { let r, g, b: Double }

    private func render(_ wash: WorktreeHeaderWash?) throws -> (CGImage, (Int, Int) -> Pixel) {
        let renderer = ImageRenderer(content: Fixture(wash: wash))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        return (image, { x, y in
            let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
            return Pixel(r: Double(color?.redComponent ?? 0), g: Double(color?.greenComponent ?? 0), b: Double(color?.blueComponent ?? 0))
        })
    }

    @Test("@spec LAYOUT-2.192: While the selected worktree has an emoji, the application shall draw a blurred smear of it from the left and a tilted watermark of it on the right behind the window header and the top row of agent tabs, leaving terminal content and emoji-less worktrees unchanged.")
    func washCoversHeaderAndTopTabsOnly() throws {
        let (_, plain) = try render(nil)
        let (_, washed) = try render(WorktreeHeaderWash(emoji: "🔥", background: Self.background, isDark: true))
        let base = plain(450, 200)

        // Without an emoji the header is exactly today's background.
        for (x, y) in [(40, 20), (860, 20), (40, 58), (450, 200)] {
            let p = plain(x, y)
            #expect(abs(p.r - base.r) < 0.02 && abs(p.g - base.g) < 0.02 && abs(p.b - base.b) < 0.02)
        }
        // The smear warms the left of both the breadcrumb and the tab row.
        for (x, y) in [(60, 20), (60, 58)] {
            let p = washed(x, y)
            #expect(p.r - base.r > 0.06, "smear missing at (\(x), \(y)): \(p)")
            #expect(p.r > p.b + 0.04, "smear is not tinted by the emoji at (\(x), \(y)): \(p)")
        }
        // The watermark sits at the right edge of the band.
        let mark = washed(870, 40)
        #expect(abs(mark.r - base.r) + abs(mark.g - base.g) + abs(mark.b - base.b) > 0.1, "watermark missing: \(mark)")
        // Terminal content below the tab row stays untouched.
        for (x, y) in [(60, 140), (870, 140), (450, 260)] {
            let p = washed(x, y)
            #expect(abs(p.r - base.r) < 0.02 && abs(p.g - base.g) < 0.02 && abs(p.b - base.b) < 0.02,
                    "wash leaked into terminal at (\(x), \(y)): \(p)")
        }
    }
}
