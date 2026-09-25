import AppKit
import GhosttyKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree terminal artwork")
@MainActor
struct WorktreeTerminalBackgroundTests {
    #if GRAFTTY_PAGED_HISTORY
    @Test("@spec TERM-9.4: While a follower displays preceding history, the application shall preserve the source terminal's runtime font size in the history mirror when artwork is applied or removed.", arguments: [false, true])
    func historyMirrorPreservesRuntimeFontSize(initialArtwork: Bool) throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let base = GhosttyConfig()
        let artwork = try GhosttyConfig(forWorktreeArtwork: base)
        let app = GhosttyApp(config: base) { _, _ in true }
        defer { withExtendedLifetime(app) {} }
        var factory = SurfaceHandleGhosttySurfaceFactory.live
        factory.create = { app, options in
            var config = options.pointee
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            config.receive_userdata = nil
            config.receive_buffer = { _, _, _ in }
            config.receive_resize = { _, _, _, _, _ in }
            config.command = nil
            config.initial_input = nil
            return ghostty_surface_new(app, &config)
        }
        let handle = try #require(SurfaceHandle(
            terminalID: .init(), app: app.app, worktreePath: NSTemporaryDirectory(),
            socketPath: "", surfaceFactory: factory
        ))
        let configuredSize = ghostty_surface_font_size(handle.surface)
        let zoomedSize: Float = configuredSize == 28 ? 36 : 28
        let action = "set_font_size:\(zoomedSize)"
        #expect(action.withCString { ghostty_surface_binding_action(handle.surface, $0, UInt(action.utf8.count)) })
        handle.setWorktreeArtworkConfig(initialArtwork ? artwork : nil, base: base)

        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        view.wantsLayer = true
        let history = try #require(handle.makeFollowerHistorySurface(
            in: view, scale: NSScreen.main?.backingScaleFactor ?? 2
        ))
        defer { ghostty_surface_free(history) }
        #expect(ghostty_surface_font_size(history) == zoomedSize)
        for config in [artwork, base, artwork] {
            config.apply(to: history, in: view)
            #expect(ghostty_surface_font_size(history) == zoomedSize)
            #expect(ghostty_surface_size(history).cell_width_px == handle.queryGridSize().cell_width_px)
            #expect(ghostty_surface_size(history).cell_height_px == handle.queryGridSize().cell_height_px)
        }
    }
    #endif

    @Test("@spec LAYOUT-2.79: When a worktree has artwork, the application shall display one continuous color gradient sampled from its map landmark behind the entire window and all terminal panes, without enlarging image pixels, fading completely into the Ghostty theme background at 75% of the window height.", arguments: [false, true])
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
        #expect(left.redComponent + left.blueComponent > 2 * left.greenComponent + 0.1)
        #expect(right.redComponent + right.blueComponent > 2 * right.greenComponent + 0.1)
        let fading = try pixel(50, 70)
        #expect(fading.redComponent + fading.blueComponent - 2 * fading.greenComponent
            < left.redComponent + left.blueComponent - 2 * left.greenComponent)
        let midpoint = try pixel(50, 100)
        let lower = try pixel(50, 130)
        #expect(midpoint.redComponent + midpoint.blueComponent > 2 * midpoint.greenComponent + 0.04)
        #expect(lower.redComponent + lower.blueComponent > 2 * lower.greenComponent + 0.02)
        #expect(lower.redComponent + lower.blueComponent - 2 * lower.greenComponent
            < midpoint.redComponent + midpoint.blueComponent - 2 * midpoint.greenComponent)
        for y in [150, 175, 199] {
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

    @Test func gradientDoesNotEnlargeTheImageBoundary() throws {
        let image = NSImage(size: NSSize(width: 400, height: 200))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 200, height: 200).fill()
        NSColor.blue.setFill()
        NSRect(x: 200, y: 0, width: 200, height: 200).fill()
        image.unlockFocus()
        let renderer = ImageRenderer(content: WorktreeTerminalBackground(
            image: image, backgroundColor: .black
        ).frame(width: 400, height: 200))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        let left = try #require(bitmap.colorAt(x: 198, y: 5)?.usingColorSpace(.deviceRGB))
        let right = try #require(bitmap.colorAt(x: 202, y: 5)?.usingColorSpace(.deviceRGB))
        #expect(abs(left.redComponent - right.redComponent) < 0.03)
        #expect(abs(left.blueComponent - right.blueComponent) < 0.03)
    }

    @Test func windowBackdropUsesOneImageAcrossNavigationColumns() async throws {
        _ = NSApplication.shared
        let image = NSImage(size: NSSize(width: 900, height: 500))
        image.lockFocus()
        for (index, color) in [NSColor.red, .green, .blue].enumerated() {
            color.setFill()
            NSRect(x: index * 300, y: 0, width: 300, height: 500).fill()
        }
        image.unlockFocus()
        let layout = NavigationSplitView {
            Color.clear.navigationSplitViewColumnWidth(200)
        } detail: {
            HStack(spacing: 0) {
                Color.clear
                Divider()
                Color.clear
            }
        }
        .modifier(WorktreeWindowArtwork(image: image, backgroundColor: .black))
        .preferredColorScheme(.dark)
        let host = NSHostingView(rootView: layout)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 900, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        func pixel(_ x: Int, _ y: Int) throws -> NSColor {
            try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB))
        }
        let leftDetail = try pixel(260, 60)
        let center = try pixel(450, 60)
        let right = try pixel(760, 60)
        #expect(max(leftDetail.redComponent, leftDetail.greenComponent, leftDetail.blueComponent) > 0.05)
        #expect(max(center.redComponent, center.greenComponent, center.blueComponent) > 0.05)
        #expect(max(right.redComponent, right.greenComponent, right.blueComponent) > 0.05)
        let bottom = try pixel(760, 400)
        #expect(bottom.redComponent < 0.01 && bottom.greenComponent < 0.01 && bottom.blueComponent < 0.01)
        if let path = ProcessInfo.processInfo.environment["GRAFTTY_WINDOW_ARTWORK_RENDER_PATH"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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
