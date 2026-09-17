import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree terminal artwork")
@MainActor
struct WorktreeTerminalBackgroundTests {
    @Test("@spec LAYOUT-2.79: When a worktree has artwork, the application shall display one continuous image behind the entire terminal split layout, strongest at the top and fading completely into the Ghostty theme background by the vertical midpoint.", arguments: [false, true])
    func fadesAcrossWholeLayout(isDark: Bool) throws {
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        NSColor.blue.setFill()
        NSRect(x: 200, y: 0, width: 200, height: 200).fill()
        image.unlockFocus()
        let renderer = ImageRenderer(content: WorktreeTerminalBackground(
            image: image, backgroundColor: isDark ? .black : .white
        ).frame(width: 400, height: 200))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)
        #expect(rendered.width == 400)
        #expect(rendered.height == 200)
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        func pixel(_ x: Int, _ y: Int) throws -> NSColor {
            try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        }
        let left = try pixel(50, 5)
        let right = try pixel(250, 5)
        #expect(left.redComponent > left.blueComponent + 0.1)
        #expect(right.blueComponent > right.redComponent + 0.1)
        let fading = try pixel(50, 70)
        #expect(fading.redComponent - fading.blueComponent < left.redComponent - left.blueComponent)
        for y in [100, 150, 199] {
            for x in [50, 250] {
                let color = try pixel(x, y)
                let expected: CGFloat = isDark ? 0 : 1
                #expect(abs(color.redComponent - expected) < 0.01)
                #expect(abs(color.greenComponent - expected) < 0.01)
                #expect(abs(color.blueComponent - expected) < 0.01)
                #expect(color.alphaComponent == 1)
            }
        }
    }

    @Test("@spec TERM-9.3: While a shared worktree backdrop is displayed, the application shall make only the terminal's default background transparent, preserve explicit cell backgrounds and inherited Ghostty settings, and retain the original configuration for panes without artwork.")
    func artworkConfigPreservesThemeAndBaseConfig() throws {
        #expect(ghostty_init(0, nil) == 0)
        let base = GhosttyConfig()
        let originalOpacity = base.double(forKey: "background-opacity")
        let variant = try GhosttyConfig(forWorktreeArtwork: base)
        #expect(variant.double(forKey: "background-opacity") == 0)
        #expect(base.double(forKey: "background-opacity") == originalOpacity)
        for key in ["background", "foreground", "cursor-color"] {
            #expect(variant.color(forKey: key)?.r == base.color(forKey: key)?.r)
            #expect(variant.color(forKey: key)?.g == base.color(forKey: key)?.g)
            #expect(variant.color(forKey: key)?.b == base.color(forKey: key)?.b)
        }
        var cells = true
        let key = "background-opacity-cells"
        #expect(key.withCString { ghostty_config_get(variant.config, &cells, $0, UInt(key.utf8.count)) })
        #expect(!cells)
        #expect(ghostty_config_diagnostics_count(variant.config) == ghostty_config_diagnostics_count(base.config))
    }

    @Test("Native terminal layers reveal the shared background and restore their configured opacity")
    func nativeLayerTransparency() throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let base = GhosttyConfig()
        let artwork = try GhosttyConfig(forWorktreeArtwork: base)
        let app = GhosttyApp(config: base) { _, _ in true }
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.wantsLayer = true
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_buffer = { _, _, _ in }
        config.receive_resize = { _, _, _, _, _ in }
        let surface = try #require(ghostty_surface_new(app.app, &config))
        defer {
            ghostty_surface_free(surface)
            withExtendedLifetime(app) {}
        }
        artwork.apply(to: surface, in: view)
        #expect(view.layer?.isOpaque == false)
        base.apply(to: surface, in: view)
        #expect(view.layer?.isOpaque == ((base.double(forKey: "background-opacity") ?? 1) >= 1))
    }
}
