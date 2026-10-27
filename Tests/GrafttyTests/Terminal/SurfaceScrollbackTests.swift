import AppKit
import GhosttyKit
import GrafttyKit
import GrafttyProtocol
import Testing
@testable import Graftty

@MainActor
struct SurfaceScrollbackTests {
    @Test("@spec CONTEXT-33: When the application jumps a Mac terminal to a timeline message, it shall read each loaded scrollback row by absolute screen row, keeping soft-wrapped rows separate, and scroll so the message's row is at the top of the viewport.")
    func readsAbsoluteRowsAndScrollsToTheMessage() async throws {
        _ = NSApplication.shared
        #expect(ghostty_init(0, nil) == 0)
        final class Scrollbar: @unchecked Sendable { var value = ghostty_action_scrollbar_s() }
        let scrollbar = Scrollbar()
        let app = GhosttyApp(config: GhosttyConfig()) { _, action in
            if action.tag == GHOSTTY_ACTION_SCROLLBAR { scrollbar.value = action.action.scrollbar }
            return true
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        let view = NSView(frame: window.contentView!.bounds)
        window.contentView = view
        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        config.scale_factor = 2
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_buffer = { _, _, _ in }
        config.receive_resize = { _, _, _, _, _ in }
        let surface = try #require(ghostty_surface_new(app.app, &config))
        window.orderBack(nil)
        defer { window.orderOut(nil); ghostty_surface_free(surface); withExtendedLifetime(app) {} }
        let columns = Int(ghostty_surface_size(surface).columns)
        try #require(columns > 10)
        let wrapped = String(repeating: "w", count: columns * 2 + 3)
        var lines = (0..<40).map { String(format: "filler-%02d", $0) }
        // Styled text checks that every build reads plain row text.
        lines += [wrapped, "> \u{1B}[1;32mPlease fix\u{1B}[0m the sidebar layout", "⏺ Looking now."]
        lines += (40..<80).map { String(format: "filler-%02d", $0) }
        let data = Data(lines.joined(separator: "\r\n").utf8)
        data.withUnsafeBytes { ghostty_surface_write_buffer(surface, $0.baseAddress!.assumingMemoryBound(to: UInt8.self), UInt($0.count)) }
        for _ in 0..<100 where scrollbar.value.total < UInt64(lines.count + 2) {
            app.tick()
            try await Task.sleep(for: .milliseconds(10))
        }
        let total = Int(scrollbar.value.total)
        let snapshot = try #require(SurfaceHandle.scrollbackRows(surface, total: total, limit: ScrollbackMap.readLimit))
        #expect(snapshot.rows.count == total && snapshot.firstRow == 0)
        // The wrapped line occupies three rows, so the prompt is row 43, not 41.
        #expect(snapshot.rows[43] == "> Please fix the sidebar layout")
        let tail = try #require(SurfaceHandle.scrollbackRows(surface, total: total, limit: 10))
        #expect(tail.firstRow == total - 10 && tail.rows == Array(snapshot.rows.suffix(10)))
        let map = ScrollbackMap.locate([.init(eventID: "a", kind: .input, text: "Please fix the sidebar layout")], in: snapshot)
        let row = try #require(map.row(for: "a"))
        #expect(row == 43)
        SurfaceHandle.scroll(surface, toRow: row)
        var text = ghostty_text_s()
        let top = ghostty_selection_s(
            top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 0),
            bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: UInt32(columns - 1), y: 0),
            rectangle: false)
        try #require(ghostty_surface_read_text(surface, top, &text))
        defer { ghostty_surface_free_text(surface, &text) }
        let topRow = text.text.map { String(decoding: Data(bytes: $0, count: Int(text.text_len)), as: UTF8.self) }
        #expect(topRow == "> Please fix the sidebar layout")
    }
}
