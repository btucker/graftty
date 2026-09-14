import AppKit
import GhosttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

@MainActor
struct MacFollowerTerminalViewTests {
    @Test("@spec OWN-2.5: While a Mac pane follows another display, the application shall preserve the leader's native grid, shrink it to fit the pane width without enlarging the configured font, and restore the Mac's physical viewport before taking control.")
    func followerFitsNativeGridAndRestoresPhysicalSize() throws {
        let terminal = SurfaceNSView()
        let surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        terminal.surface = surface
        var pixels: CGSize?
        terminal.surfaceOperations = .init(
            setSize: { _, width, height in pixels = CGSize(width: Int(width), height: Int(height)) },
            size: { _ in .testSize132x43 }, refresh: { _ in }
        )
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.followerGrid = try DisplayGrid(cols: 200, rows: 50)
        view.layout()
        #expect(pixels == CGSize(width: 2400, height: 800))
        #expect(abs(view.scaledView.frame.width - view.scrollView.contentSize.width) < 0.1)
        view.followerGrid = try DisplayGrid(cols: 45, rows: 70)
        view.layout()
        #expect(pixels == CGSize(width: 540, height: 1120))
        #expect(view.scaledView.frame.size == view.scaledView.bounds.size)
        #expect(view.scaledView.frame.height > view.scrollView.contentSize.height)
        #expect(abs(view.scrollView.contentView.bounds.maxY - view.scrollView.documentView!.bounds.height) < 1)
        view.followerGrid = nil
        view.layout()
        #expect(terminal.bounds.size == view.scrollView.contentSize)
        #expect(pixels == terminal.convertToBacking(terminal.bounds.size))
        terminal.surface = nil
    }
    #if GRAFTTY_PAGED_HISTORY
    @Test("A mounted Mac follower preserves the native grid and displays preceding styled history without input.")
    func mountedNativeFollowerDisplaysHistory() async throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let terminal = SurfaceNSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let scale = window.backingScaleFactor
        func createSurface(view: NSView, inherited: ghostty_surface_t? = nil) -> ghostty_surface_t? {
            var config = inherited.map { ghostty_surface_inherited_config($0, GHOSTTY_SURFACE_CONTEXT_SPLIT) }
                ?? ghostty_surface_config_new()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
            config.scale_factor = Double(scale)
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
            config.receive_buffer = { _, _, _ in }
            config.receive_resize = { _, _, _, _, _ in }
            return ghostty_surface_new(app.app, &config)
        }
        let source = try #require(createSurface(view: terminal))
        terminal.surface = source
        terminal.setFrameSize(terminal.frame.size)
        let follower = MacFollowerTerminalView(
            terminalView: terminal, metrics: { ghostty_surface_size(source) },
            makeHistorySurface: { view, _ in createSurface(view: view, inherited: source) }
        )
        window.contentView = follower
        window.orderBack(nil)
        defer {
            follower.followerGrid = nil
            follower.layout()
            follower.removeFromSuperview()
            window.orderOut(nil)
            terminal.surface = nil
            ghostty_surface_free(source)
            withExtendedLifetime(app) {}
        }
        follower.followerGrid = try DisplayGrid(cols: 200, rows: 50)
        follower.layout()
        #expect(ghostty_surface_size(source).columns == 200)
        #expect(ghostty_surface_size(source).rows == 50)
        for _ in 0..<100 where !ghostty_surface_grid_matches(source, 200, 50) {
            app.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ghostty_surface_grid_matches(source, 200, 50))
        let data = Data((0..<100).map { String(format: "mac-row-%03d", $0) }.joined(separator: "\r\n").utf8)
        data.withUnsafeBytes { bytes in
            ghostty_surface_write_buffer(source, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
        for _ in 0..<100 {
            app.tick()
            if Self.viewportText(source)?.contains("mac-row-099") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        follower.updateScrollbar(.init(total: 100, offset: 50, len: 50))
        for _ in 0..<100 {
            follower.layout()
            app.tick()
            if let history = follower.historySurfaceForTesting,
               Self.viewportText(history)?.contains("mac-row-049") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let history = try #require(follower.historySurfaceForTesting)
        #expect(Self.viewportText(history)?.contains("mac-row-049") == true)
        #expect(Self.viewportText(history)?.contains("mac-row-099") == false)
        #expect(Self.viewportText(source)?.contains("mac-row-099") == true)
        #expect(ghostty_surface_size(source).columns == 200)
        #expect(ghostty_surface_size(source).rows == 50)
        follower.scrollView.contentView.scroll(to: .zero)
        follower.scrollView.reflectScrolledClipView(follower.scrollView.contentView)
        #expect(Self.viewportText(source)?.contains("mac-row-000") == true)
        follower.scrollView.contentView.scroll(to: CGPoint(x: 0, y: follower.scrollView.documentView!.bounds.height - follower.scrollView.contentSize.height))
        follower.scrollView.reflectScrolledClipView(follower.scrollView.contentView)
        #expect(Self.viewportText(source)?.contains("mac-row-099") == true,
                "clip=\(follower.scrollView.contentView.bounds) doc=\(follower.scrollView.documentView!.bounds) text=\(Self.viewportText(source)?.suffix(100) ?? "nil")")
        follower.followerGrid = nil
        follower.layout()
        let pixels = terminal.convertToBacking(terminal.bounds.size)
        #expect(ghostty_surface_size(source).width_px == UInt32(pixels.width))
        #expect(ghostty_surface_size(source).height_px == UInt32(pixels.height))
    }

    private static func viewportText(_ surface: ghostty_surface_t) -> String? {
        let selection = ghostty_selection_s(
            top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text else { return nil }
        return String(decoding: UnsafeBufferPointer(start: UnsafeRawPointer(bytes).assumingMemoryBound(to: UInt8.self), count: Int(text.text_len)), as: UTF8.self)
    }
    #endif

}
