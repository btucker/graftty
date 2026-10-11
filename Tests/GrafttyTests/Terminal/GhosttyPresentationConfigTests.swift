import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("@spec IOS-4.45: When a Mac supplies terminal presentation to GrafttyMobile, the application shall send its resolved background, foreground, and ANSI palette without host theme or config-file references, preserve non-color settings including fonts and keybindings, and retain explicit overrides over the selected host theme branch.")
@MainActor
struct GhosttyPresentationConfigTests {
    @Test(arguments: ["?\"included\"", "\"?included\"", "\"\"?included\"\""])
    func quotedIncludePathsMatchNativeGhostty(directive: String) throws {
        #expect(ghostty_init(0, nil) == 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "font-size = 18\n".write(to: directory.appendingPathComponent("included"), atomically: true, encoding: .utf8)
        try "font-size = 21\n".write(to: directory.appendingPathComponent("?included"), atomically: true, encoding: .utf8)
        let root = directory.appendingPathComponent("config")
        try "font-size = 12\nconfig-file = \(directive)\n".write(to: root, atomically: true, encoding: .utf8)

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, root.path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        var nativeSize: Float = 0
        #expect(ghostty_config_get(config, &nativeSize, "font-size", 9))
        let expectedSize: Float = directive.hasPrefix("\"\"") ? 21 : 18
        #expect(nativeSize == expectedSize)

        let exported = GhosttyConfigReader.portableConfig(paths: [root.path])
        #expect(exported.split(separator: "\n").last == "font-size = \(Int(nativeSize))")
        #expect(!exported.contains("config-file"))
    }

    @Test func rootIncludedByCycleMatchesNativeGhosttyLoadOrder() throws {
        #expect(ghostty_init(0, nil) == 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("config")
        let child = directory.appendingPathComponent("child")
        try "font-size = 10\nconfig-file = child\n".write(to: root, atomically: true, encoding: .utf8)
        try "font-size = 16\nconfig-file = config\n".write(to: child, atomically: true, encoding: .utf8)

        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, root.path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) > 0)
        var nativeSize: Float = 0
        #expect(ghostty_config_get(config, &nativeSize, "font-size", 9))
        #expect(nativeSize == 10)

        // Native Ghostty loads the root again as an include, then rejects the
        // repeated child. Pre-seeding roots in the include set would yield 16.
        let exported = GhosttyConfigReader.portableConfig(paths: [root.path])
        let sizes = exported.split(separator: "\n").filter { $0.hasPrefix("font-size") }
        #expect(sizes == ["font-size = 10", "font-size = 16", "font-size = 10"])
    }

    @Test(arguments: [false, true])
    func exportsSelectedThemeAndExplicitOverrides(paired: Bool) throws {
        #expect(ghostty_init(0, nil) == 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let light = directory.appendingPathComponent("light")
        let dark = directory.appendingPathComponent("dark")
        try "background = #eeeeee\nforeground = #112233\npalette = 1=#abcdef\n".write(to: light, atomically: true, encoding: .utf8)
        try "background = #101010\nforeground = #f0f0f0\npalette = 1=#cc241d\n".write(to: dark, atomically: true, encoding: .utf8)
        let theme = paired ? "light:\(light.path),dark:\(dark.path)" : dark.path
        let text = """
        theme = \(theme)
        foreground = #123456
        palette = 2=#98971a
        font-family = Menlo
        font-size = 16
        keybind = ctrl+a=select_all
        """
        let file = directory.appendingPathComponent("config")
        try text.write(to: file, atomically: true, encoding: .utf8)
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, file.path)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        let exported = GhosttyPresentationConfig.render(config: config, text: text)
        #expect(!exported.contains("theme ="))
        #expect(exported.contains("font-family = Menlo"))
        #expect(exported.contains("font-size = 16"))
        #expect(exported.contains("keybind = ctrl+a=select_all"))
        #expect(exported.contains("foreground = #123456"))
        #expect(exported.contains("palette = 2=#98971a"))
        var background = ghostty_config_color_s()
        #expect(ghostty_config_get(config, &background, "background", 10))
        let expectedBackground = String(format: "background = #%02x%02x%02x", background.r, background.g, background.b)
        #expect(exported.contains(expectedBackground))
        var palette = ghostty_config_palette_s()
        #expect(ghostty_config_get(config, &palette, "palette", 7))
        let themeRed = palette.colors.1
        #expect(exported.contains(String(format: "palette = 1=#%02x%02x%02x", themeRed.r, themeRed.g, themeRed.b)))
        #expect(exported.split(separator: "\n").filter { $0.hasPrefix("palette =") }.count >= 256)
        // A portable export must still load after the host's theme files disappear.
        try FileManager.default.removeItem(at: light)
        try FileManager.default.removeItem(at: dark)
        try exported.write(to: file, atomically: true, encoding: .utf8)
        let mobile = try #require(ghostty_config_new())
        defer { ghostty_config_free(mobile) }
        ghostty_config_load_file(mobile, file.path)
        ghostty_config_finalize(mobile)
        #expect(ghostty_config_diagnostics_count(mobile) == 0)
    }
}
