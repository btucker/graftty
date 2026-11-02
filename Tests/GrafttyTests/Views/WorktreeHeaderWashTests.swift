import AppKit
import SwiftUI
import Testing
import GrafttyCommandUI
import GrafttyProtocol
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

    @Test("@spec LAYOUT-2.194: While the selected worktree is its project's main checkout, the application shall draw the header wash from the project icon, or from the project's initials in its accent color when the project has no icon.")
    func mainCheckoutWashUsesProjectIcon() throws {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor(srgbRed: 0.1, green: 0.35, blue: 1, alpha: 1).setFill(); rect.fill(); return true
        }
        let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
            .representation(using: .png, properties: [:]))
        let project = SidebarProject(id: "repo", repositoryID: "/repo", name: "Graftty", accentHex: "22cc44")
        let (_, plain) = try render(nil)
        let base = plain(450, 200)

        // The main checkout ignores any emoji and draws from the blue icon.
        let iconWash = try #require(WorktreeHeaderWash(identity: .resolve(isMainCheckout: true, emoji: "🔥"),
            project: project, iconData: png, background: Self.background, isDark: true))
        let (_, iconed) = try render(iconWash)
        for (x, y) in [(60, 20), (60, 58)] {
            let p = iconed(x, y)
            #expect(p.b - base.b > 0.06 && p.b > p.r + 0.04, "icon smear missing or not blue at (\(x), \(y)): \(p)")
        }
        let mark = iconed(870, 40)
        #expect(mark.b - base.b > 0.06, "icon watermark missing: \(mark)")

        // Without an icon, the wash falls back to the project's green accent.
        let initialsWash = try #require(WorktreeHeaderWash(identity: .project, project: project, iconData: nil,
            background: Self.background, isDark: true))
        let (_, initialed) = try render(initialsWash)
        let accent = initialed(60, 20)
        #expect(accent.g - base.g > 0.04 && accent.g > accent.r && accent.g > accent.b, "accent smear missing: \(accent)")

        // A linked worktree without an emoji still gets no wash.
        #expect(WorktreeHeaderWash(identity: .resolve(isMainCheckout: false, emoji: nil), project: project,
            iconData: png, background: Self.background, isDark: true) == nil)
    }
}
