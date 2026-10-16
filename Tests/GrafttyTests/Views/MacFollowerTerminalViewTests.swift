import AppKit
import GhosttyKit
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

@MainActor
struct MacFollowerTerminalViewTests {
    @Test("@spec TERM-11.21: When a Mac pane resumes leading after applying an attachment grid, the application shall restore its full viewport before resizing the terminal, regardless of scrollbar style.", arguments: [NSScroller.Style.overlay, .legacy])
    func attachmentGridRestoresFullLeaderViewport(style: NSScroller.Style) throws {
        _ = NSApplication.shared
        let window = FollowerBackingWindow(size: CGSize(width: 640, height: 400), scale: 2)
        defer { window.close() }
        let terminal = SurfaceNSView()
        defer { terminal.surface = nil }
        var resizes: [CGSize] = []
        var metrics = ghostty_surface_size_s(columns: 106, rows: 50, width_px: 1280, height_px: 800,
                                            cell_width_px: 12, cell_height_px: 16)
        terminal.surfaceOperations = .init(
            setSize: { _, width, height in
                resizes.append(CGSize(width: Int(width), height: Int(height)))
                metrics.width_px = width
                metrics.height_px = height
                metrics.columns = UInt16(width / 12)
                metrics.rows = UInt16(height / 16)
            },
            size: { _ in metrics }, refresh: { _ in }
        )
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { metrics })
        window.contentView = view
        terminal.surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        view.scrollView.scrollerStyle = style
        view.layout()
        resizes.removeAll()
        for index in 0..<10 {
            view.followerGrid = try DisplayGrid(cols: 106, rows: 50)
            view.layout()
            view.followerGrid = nil
            view.layout()
            view.updateScrollbar(.init(total: UInt64(100 + index), offset: UInt64(57 + index), len: 43))
            view.layoutSubtreeIfNeeded()
        }
        #expect(!view.scrollView.hasVerticalScroller)
        #expect(!view.scrollView.hasHorizontalScroller)
        #expect(terminal.bounds.size == view.bounds.size)
        #expect(resizes.allSatisfy { $0 == CGSize(width: 1280, height: 800) }, "Unexpected viewport sizes: \(resizes)")
    }

    @Test("@spec TERM-2.7: When a user clicks or types in a native Mac terminal pane, the application shall update the pane focus model used for dimming even when a scroll-view wrapper consumes SwiftUI tap gestures.")
    func nativeClickUpdatesFocusAndDimming() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let terminal = SurfaceNSView()
        let wrapper = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        window.contentView = wrapper
        let first = PaneSlotID()
        let second = PaneSlotID()
        var selected = first
        wrapper.onFocusTerminal = { selected = second }
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 100, y: 100), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        terminal.mouseDown(with: click)
        #expect(window.firstResponder === terminal)
        #expect(selected == second)
        #expect(!GhosttyTheme.fallback.paneFocusDimmingStyle(isUnfocused: selected != second).isVisible)
        selected = first
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
        terminal.keyDown(with: key)
        #expect(selected == second)
        // SwiftUI can replace the callback while retaining the native wrapper.
        wrapper.onFocusTerminal = { selected = first }
        terminal.mouseDown(with: click)
        #expect(selected == first)
    }

    @Test("@spec OWN-2.9: When a Mac terminal receives a zoom command or pinch, the application shall change the native font while leading and change only presentation scale while following, without taking display ownership.")
    func zoomRoutesByDisplayOwnership() throws {
        let terminal = SurfaceNSView()
        terminal.surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        defer { terminal.surface = nil }
        var actions: [String] = []
        terminal.surfaceOperations = .init(setSize: { _, _, _ in }, size: { _ in .testSize132x43 }, refresh: { _ in })
        terminal.surfaceOperations.bindingAction = { _, action in actions.append(action); return true }
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.layout()
        view.performZoomAction(.increaseFontSize)
        view.performZoomAction(.resetFontSize)
        view.beginMagnification()
        view.magnify(by: 0.25, around: CGPoint(x: 300, y: 200))
        #expect(actions == ["increase_font_size:1", "reset_font_size", "increase_font_size:2"])
        actions.removeAll()
        view.followerGrid = try DisplayGrid(cols: 200, rows: 50)
        view.layout()
        view.performZoomAction(.increaseFontSize)
        #expect(view.followerZoomScale > 1)
        view.performZoomAction(.resetFontSize)
        #expect(view.followerZoomScale == 1)
        view.beginMagnification()
        view.magnify(by: 0.5, around: CGPoint(x: 300, y: 200))
        #expect(view.followerZoomScale == 1.5)
        #expect(actions.isEmpty)
        #expect(view.followerGrid == (try DisplayGrid(cols: 200, rows: 50)))
    }

    @Test("@spec OWN-2.8: When a Mac follower is magnified, the application shall scale its entire canvas and allow horizontal scrolling without changing its native grid, then discard the presentation zoom when it becomes leader.")
    func followerZoomKeepsNativePixels() throws {
        let terminal = SurfaceNSView()
        terminal.surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        defer { terminal.surface = nil }
        var pixels: CGSize?
        var resizeCount = 0
        terminal.surfaceOperations = .init(
            setSize: { _, width, height in
                pixels = CGSize(width: Int(width), height: Int(height))
                resizeCount += 1
            },
            size: { _ in .testSize132x43 }, refresh: { _ in }
        )
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.followerGrid = try DisplayGrid(cols: 200, rows: 50)
        view.layout()
        let nativePixels = pixels
        let nativeBounds = terminal.bounds
        let nativeResizeCount = resizeCount
        view.setFollowerZoomScale(2, around: CGPoint(x: 300, y: 200))
        #expect(pixels == nativePixels)
        #expect(terminal.bounds == nativeBounds)
        #expect(resizeCount == nativeResizeCount)
        #expect(view.scrollView.documentView!.frame.width == 1200)
        #expect(view.scaledView.frame.width == 1200)
        #expect(view.scrollView.contentView.bounds.minX == 300)
        view.layout()
        #expect(view.scrollView.contentView.bounds.minX == 300)
        view.followerGrid = nil
        view.layout()
        #expect(view.followerZoomScale == 1)
        #expect(view.scrollView.contentView.bounds.origin == .zero)
        #expect(terminal.bounds.size == view.scrollView.contentSize)
    }

    @Test("@spec OWN-2.5: While a Mac pane follows another display, the application shall preserve the leader's native grid, shrink it to fit the pane width without enlarging the configured font, center a narrower canvas, and restore the Mac's physical viewport before taking control.")
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
        #expect(abs(view.scaledView.frame.midX - view.scrollView.contentSize.width / 2) < 0.1)
        #expect(view.scaledView.frame.height > view.scrollView.contentSize.height)
        #expect(abs(view.scrollView.contentView.bounds.maxY - view.scrollView.documentView!.bounds.height) < 1)
        view.followerGrid = nil
        view.layout()
        #expect(terminal.bounds.size == view.scrollView.contentSize)
        #expect(pixels == terminal.convertToBacking(terminal.bounds.size))
        terminal.surface = nil
    }
    @Test("@spec OWN-2.11: While a Mac follower canvas is narrower than its pane with room for framing, the application shall present the terminal and its scrollback inside one centered, rounded, theme-matched frame with a fine border and soft shadow while preserving the leader's native grid.", arguments: [CGFloat(1), 2])
    func narrowFollowerUsesRaisedCanvas(displayScale: CGFloat) throws {
        _ = NSApplication.shared
        let window = FollowerBackingWindow(size: CGSize(width: 1000, height: 700), scale: displayScale)
        defer { window.close() }
        let terminal = SurfaceNSView()
        defer { terminal.surface = nil }
        var pixels: CGSize?
        terminal.surfaceOperations = .init(
            setSize: { _, width, height in pixels = CGSize(width: Int(width), height: Int(height)) },
            size: { _ in .testSize132x43 }, refresh: { _ in }
        )
        terminal.surfaceOperations.readScrollbar = { _ in nil }
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        window.contentView = view
        terminal.surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        view.followerGrid = try DisplayGrid(cols: 45, rows: 43)
        view.layout()
        let frame = try #require(view.scrollView.superview)
        #expect(frame !== view)
        #expect(frame.frame.minX > 0 && frame.frame.maxX < view.bounds.width)
        #expect(frame.frame.minY > 0 && frame.frame.maxY < view.bounds.height)
        #expect(abs(frame.frame.midX - view.bounds.midX) < 0.5)
        #expect(abs(frame.frame.midY - view.bounds.midY) < 0.5)
        #expect(frame.layer?.cornerRadius == 8)
        #expect((frame.layer?.borderWidth ?? 0) > 0)
        let shadow = try #require(view.layer?.sublayers?.first { $0.shadowOpacity > 0 })
        #expect(shadow.frame == frame.frame)
        #expect(shadow.shadowPath != nil)
        #expect(!shadow.masksToBounds)
        #expect(frame.layer?.masksToBounds == true)
        #expect(view.scrollView.layer?.masksToBounds == true)
        #expect(view.scrollView.contentSize.height >= view.bounds.height - 64)
        let viewport = view.scrollView.convert(view.scrollView.bounds, to: frame)
        let radius = try #require(frame.layer?.cornerRadius)
        #expect(viewport.minX >= radius && viewport.maxX <= frame.bounds.maxX - radius)
        #expect(viewport.minY >= radius && viewport.maxY <= frame.bounds.maxY - radius)
        #expect(pixels == CGSize(width: 540, height: 688))
        #expect(terminal.bounds.size == CGSize(width: 540 / displayScale, height: 688 / displayScale))
        let before = frame.frame
        view.updateScrollbar(.init(total: 150, offset: 107, len: 43))
        #expect(frame.frame == before, "The history and live screen share a stationary frame.")
        #expect(pixels == CGSize(width: 540, height: 688))
    }

    @Test("Follower framing clears when the canvas fills the pane and when the Mac takes control.", arguments: [CGFloat(1), 2])
    func raisedCanvasRestoresFullPane(displayScale: CGFloat) throws {
        _ = NSApplication.shared
        let window = FollowerBackingWindow(size: CGSize(width: 640, height: 400), scale: displayScale)
        defer { window.close() }
        let terminal = SurfaceNSView()
        defer { terminal.surface = nil }
        var resizes: [CGSize] = []
        terminal.surfaceOperations = .init(
            setSize: { _, width, height in resizes.append(CGSize(width: Int(width), height: Int(height))) },
            size: { _ in .testSize132x43 }, refresh: { _ in }
        )
        terminal.surfaceOperations.readScrollbar = { _ in nil }
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        window.contentView = view
        terminal.surface = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        view.followerGrid = try DisplayGrid(cols: 45, rows: 70)
        view.layout()
        let frame = try #require(view.scrollView.superview)
        let shadow = try #require(view.layer?.sublayers?.first { $0.shadowOpacity > 0 })
        let nativeBounds = terminal.bounds
        let nativePixels = try #require(resizes.last)
        let nativePoint = CGPoint(x: 100, y: nativeBounds.height - 280)
        let pointInPane = view.scaledView.convert(nativePoint, to: view)
        let pointInClip = view.scrollView.contentView.convert(pointInPane, from: view)
        let anchor = CGPoint(x: pointInClip.x - view.scrollView.contentView.bounds.minX,
                             y: pointInClip.y - view.scrollView.contentView.bounds.minY)
        view.setFollowerZoomScale(4, around: anchor)
        let afterZoom = view.scaledView.convert(nativePoint, to: view)
        #expect(abs(afterZoom.x - pointInPane.x) < 0.5)
        #expect(abs(afterZoom.y - pointInPane.y) < 0.5)
        #expect(frame.frame == view.bounds)
        #expect(frame.layer?.cornerRadius == 0)
        #expect(frame.layer?.borderWidth == 0)
        #expect(shadow.shadowOpacity == 0)
        #expect(terminal.bounds == nativeBounds)
        #expect(resizes.allSatisfy { $0 == nativePixels })
        view.setFollowerZoomScale(1, around: CGPoint(x: 100, y: 100))
        #expect(shadow.shadowOpacity > 0)
        view.followerGrid = nil
        view.layout()
        #expect(frame.frame == view.bounds)
        #expect(shadow.shadowOpacity == 0)
        #expect(frame.layer?.cornerRadius == 0)
        #expect(terminal.bounds.size == view.bounds.size)
        #expect(terminal.followerPixelSize == nil)
    }

    @Test("Raised follower colors follow the terminal theme without resizing the native surface.", arguments: [CGFloat(1), 2])
    func raisedCanvasFollowsTheme(displayScale: CGFloat) throws {
        _ = NSApplication.shared
        let window = FollowerBackingWindow(size: CGSize(width: 640, height: 400), scale: displayScale)
        defer { window.close() }
        let terminal = SurfaceNSView()
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        window.contentView = view
        view.followerGrid = try DisplayGrid(cols: 45, rows: 43)
        view.layout()
        let nativeBounds = terminal.bounds
        let frame = try #require(view.scrollView.superview)
        let shadow = try #require(view.layer?.sublayers?.first { $0.shadowOpacity > 0 })
        let darkShadow = shadow.shadowOpacity
        view.theme = GhosttyTheme(core: GhosttyThemeColors(backgroundRGB: .init(r: 0.96, g: 0.94, b: 0.90),
                                                          foregroundRGB: .init(r: 0.12, g: 0.10, b: 0.08)))
        view.layout()
        #expect(frame.layer?.backgroundColor == view.theme.backgroundNSColor.cgColor)
        #expect(view.layer?.backgroundColor != frame.layer?.backgroundColor)
        #expect(shadow.shadowOpacity < darkShadow)
        #expect(terminal.bounds == nativeBounds)
    }

    @Test("Clicking a follower gutter focuses the terminal without sending a terminal click.", arguments: [CGFloat(1), 2])
    func followerGutterFocusesTerminal(displayScale: CGFloat) throws {
        _ = NSApplication.shared
        let window = FollowerBackingWindow(size: CGSize(width: 640, height: 400), scale: displayScale)
        defer { window.close() }
        let terminal = SurfaceNSView()
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 })
        window.contentView = view
        view.followerGrid = try DisplayGrid(cols: 45, rows: 43)
        view.layout()
        var focused = false
        view.onFocusTerminal = { focused = true }
        let target = try #require(view.hitTest(CGPoint(x: 10, y: 200)))
        #expect(target === view)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 10, y: 200), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        target.mouseDown(with: click)
        #expect(focused)
        #expect(window.firstResponder === terminal)
    }

    @Test("Unhandled wheel events leave the follower once without cycling through the scroll view.", arguments: [false, true])
    func followerScrollDoesNotCycle(fromTerminal: Bool) throws {
        _ = NSApplication.shared
        let terminal = SurfaceNSView()
        let scroll = UnhandledFollowerScrollView()
        let view = MacFollowerTerminalView(terminalView: terminal, metrics: { .testSize132x43 }, scrollView: scroll)
        view.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
        view.followerGrid = try DisplayGrid(cols: 45, rows: 10)
        view.layout()
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 24, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: cgEvent))
        if fromTerminal {
            let forward = try #require(terminal.followerScrollHandler)
            #expect(forward(event))
        } else {
            view.scrollWheel(with: event)
        }
        #expect(scroll.deliveries == 1)
    }

    #if GRAFTTY_PAGED_HISTORY
    @Test("@spec OWN-2.10: When scrollback becomes available to a taller Mac follower, the application shall fill spare height with preceding history from the current native scrollbar without requiring input or a scrollbar callback.", arguments: [UInt16(200), 80])
    func mountedNativeFollowerDisplaysHistory(columns: UInt16) async throws {
        let rows: UInt16 = columns == 200 ? 50 : 24
        let windowSize = columns == 200 ? CGSize(width: 600, height: 400) : CGSize(width: 1000, height: 700)
        let lastHistoryRow = String(format: "mac-row-%03d", 99 - Int(rows))
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let config = GhosttyConfig()
        let app = GhosttyApp(config: config) { _, _ in true }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: windowSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let terminal = SurfaceNSView(frame: CGRect(origin: .zero, size: windowSize))
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
        follower.theme = GhosttyTheme(config: config)
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
        follower.followerGrid = try DisplayGrid(cols: columns, rows: rows)
        follower.layout()
        #expect(ghostty_surface_size(source).columns == columns)
        #expect(ghostty_surface_size(source).rows == rows)
        for _ in 0..<100 where !ghostty_surface_grid_matches(source, columns, rows) {
            app.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ghostty_surface_grid_matches(source, columns, rows))
        let data = Data((0..<100).map { String(format: "mac-row-%03d", $0) }.joined(separator: "\r\n").utf8)
        data.withUnsafeBytes { bytes in
            ghostty_surface_write_buffer(source, bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt(bytes.count))
        }
        for _ in 0..<100 {
            app.tick()
            if Self.viewportText(source)?.contains("mac-row-099") == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        for _ in 0..<100 {
            app.tick()
            if let history = follower.historySurfaceForTesting,
               Self.viewportText(history)?.contains(lastHistoryRow) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let history = try #require(follower.historySurfaceForTesting)
        #expect(Self.viewportText(history)?.contains(lastHistoryRow) == true)
        #expect(Self.viewportText(history)?.contains("mac-row-099") == false)
        #expect(Self.viewportText(source)?.contains("mac-row-099") == true)
        // An earlier callback must not replace the newly sampled history.
        follower.updateScrollbar(.init(total: UInt64(rows), offset: 0, len: UInt64(rows)))
        #expect(follower.historySurfaceForTesting == history)
        #expect(ghostty_surface_size(source).columns == columns)
        #expect(ghostty_surface_size(source).rows == rows)
        if columns == 80, let directory = ProcessInfo.processInfo.environment["GRAFTTY_FOLLOWER_RENDER_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            follower.layoutSubtreeIfNeeded()
            for _ in 0..<10 {
                app.tick()
                try await Task.sleep(for: .milliseconds(10))
            }
            window.displayIfNeeded()
            let bitmap = try #require(follower.bitmapImageRepForCachingDisplay(in: follower.bounds))
            follower.cacheDisplay(in: follower.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("raised-canvas.png"))
        }
        let originalFontSize = ghostty_surface_font_size(source)
        follower.setFollowerZoomScale(1.5, around: CGPoint(x: 300, y: 200))
        #expect(ghostty_surface_size(source).columns == columns)
        #expect(ghostty_surface_size(source).rows == rows)
        #expect(ghostty_surface_font_size(source) == originalFontSize)
        if columns == 200 {
            #expect(abs(follower.scaledView.frame.width - follower.scrollView.contentSize.width * 1.5) < 1)
            #expect(follower.scrollView.contentView.bounds.minX > 0)
        }
        follower.setFollowerZoomScale(1, around: CGPoint(x: 300, y: 200))
        if columns == 80 { #expect(follower.scrollView.frame.width < follower.bounds.width) }
        follower.scrollView.contentView.scroll(to: .zero)
        follower.scrollView.reflectScrolledClipView(follower.scrollView.contentView)
        #expect(Self.viewportText(source)?.contains("mac-row-000") == true)
        follower.scrollView.contentView.scroll(to: CGPoint(x: 0, y: follower.scrollView.documentView!.bounds.height - follower.scrollView.contentSize.height))
        follower.scrollView.reflectScrolledClipView(follower.scrollView.contentView)
        #expect(Self.viewportText(source)?.contains("mac-row-099") == true,
                "clip=\(follower.scrollView.contentView.bounds) doc=\(follower.scrollView.documentView!.bounds) text=\(Self.viewportText(source)?.suffix(100) ?? "nil")")
        window.orderOut(nil)
        let readScrollbar = terminal.surfaceOperations.readScrollbar
        var hiddenReads = 0
        terminal.surfaceOperations.readScrollbar = { surface in
            hiddenReads += 1
            return readScrollbar(surface)
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(hiddenReads == 0)
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

@MainActor
private final class UnhandledFollowerScrollView: NSScrollView {
    var deliveries = 0
    override func scrollWheel(with event: NSEvent) {
        deliveries += 1
        // Model AppKit forwarding an unhandled wheel at a scroll boundary,
        // bounding the old cycle so the regression fails instead of crashing.
        if deliveries < 4 { nextResponder?.scrollWheel(with: event) }
    }
}

@MainActor
private final class FollowerBackingWindow: NSWindow {
    private let displayScale: CGFloat

    init(size: CGSize, scale: CGFloat) {
        displayScale = scale
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }

    override var backingScaleFactor: CGFloat { displayScale }
}
