import AppKit
import GhosttyKit
import Testing
@testable import Graftty

@MainActor
struct SurfaceNSViewSizingTests {
    @Test("@spec TERM-11.18: When a local terminal view joins a window after receiving an offscreen frame size or its backing properties change, the application shall resynchronize libghostty's content scale and backing-pixel viewport in that order even if its point size did not change.")
    func attachingPresizedViewResynchronizesPixels() throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        let app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        let size = CGRect(x: 0, y: 0, width: 600, height: 400)
        let terminal = SurfaceNSView(frame: size)
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(terminal).toOpaque()
        config.scale_factor = 2
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_buffer = { _, _, _ in }
        config.receive_resize = { _, _, _, _, _ in }
        let surface = try #require(ghostty_surface_new(app.app, &config))
        terminal.surface = surface
        defer {
            terminal.surface = nil
            ghostty_surface_free(surface)
            withExtendedLifetime(app) {}
        }

        var sizeCalls = 0
        var calls: [String] = []
        var observedScale: (Double, Double)?
        terminal.surfaceOperations.setSize = { surface, width, height in
            sizeCalls += 1
            calls.append("size")
            ghostty_surface_set_size(surface, width, height)
        }
        terminal.surfaceOperations.setContentScale = { surface, x, y in
            calls.append("scale")
            observedScale = (x, y)
            ghostty_surface_set_content_scale(surface, x, y)
        }
        terminal.setFrameSize(size.size)
        let offscreenCalls = sizeCalls
        calls.removeAll()
        observedScale = nil

        let window = NSWindow(contentRect: size, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let container = NSView(frame: size)
        window.contentView = container
        container.addSubview(terminal)
        defer { terminal.removeFromSuperview(); window.orderOut(nil); window.contentView = nil }
        #expect(terminal.frame.size == size.size)
        #expect(sizeCalls > offscreenCalls)
        #expect(calls.starts(with: ["scale", "size"]))
        let backingScale = Double(terminal.convertToBacking(NSSize(width: 1, height: 1)).height)
        if let observedScale {
            #expect(observedScale.0 == backingScale)
            #expect(observedScale.1 == backingScale)
        }
        let pixels = terminal.convertToBacking(terminal.bounds.size)
        let actual = ghostty_surface_size(surface)
        #expect(actual.width_px == UInt32(pixels.width))
        #expect(actual.height_px == UInt32(pixels.height))
        let attachedCalls = sizeCalls
        calls.removeAll()
        observedScale = nil
        terminal.viewDidChangeBackingProperties()
        #expect(sizeCalls > attachedCalls)
        #expect(calls.starts(with: ["scale", "size"]))
        if let observedScale { #expect(observedScale.0 == backingScale) }
    }
}
