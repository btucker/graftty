import Foundation
import GhosttyKit
import Testing
@testable import Graftty
@testable import GrafttyKit

@Suite("@spec IOS-4.45: When a Mac supplies terminal presentation to GrafttyMobile, the application shall send its resolved background, foreground, and ANSI palette without host theme or config-file references, preserve non-color settings from root and included config files including fonts and keybindings, and retain explicit overrides over the selected host theme branch.")
@MainActor
struct GhosttyPresentationConfigTests {
    @Test(arguments: ["relativeSymlink", "homeRelativeSymlink", "absoluteAlias", "literalTilde", "bomRoot", "bomChild"])
    func includePathsMatchNativeGhostty(scenario: String) throws {
        #expect(ghostty_init(0, nil) == 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("config")
        var text = "font-size = 10\n"
        let expectedSize: Float
        switch scenario {
        case "relativeSymlink", "homeRelativeSymlink":
            let shared = directory.appendingPathComponent("shared")
            try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
            try "font-size = 16\nconfig-file = nested\n".write(to: shared.appendingPathComponent("child"), atomically: true, encoding: .utf8)
            try "font-size = 22\n".write(to: shared.appendingPathComponent("nested"), atomically: true, encoding: .utf8)
            try "font-size = 30\n".write(to: directory.appendingPathComponent("nested"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("child-link"), withDestinationURL: shared.appendingPathComponent("child"))
            if scenario == "relativeSymlink" {
                text += "config-file = child-link\n"
                expectedSize = 22
            } else {
                let home = ProcessInfo.processInfo.environment["HOME"]
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
                let parents = String(repeating: "../", count: home.split(separator: "/").count)
                text += "config-file = ~/\(parents)\(directory.path.dropFirst())/child-link\n"
                // Native ~/ expansion retains the symlink spelling, so the
                // child's nested include resolves beside the symlink itself.
                expectedSize = 30
            }
        case "absoluteAlias":
            try "font-size = 16\n".write(to: directory.appendingPathComponent("child"), atomically: true, encoding: .utf8)
            try "font-size = 20\n".write(to: directory.appendingPathComponent("middle"), atomically: true, encoding: .utf8)
            text += "config-file = \(directory.path)/child\nconfig-file = \(directory.path)/middle\nconfig-file = \(directory.path)/./child\n"
            expectedSize = 16
        case "literalTilde":
            try "font-size = 18\n".write(to: directory.appendingPathComponent("~"), atomically: true, encoding: .utf8)
            text += "config-file = ~\n"
            expectedSize = 18
        case "bomRoot":
            try "font-size = 18\n".write(to: directory.appendingPathComponent("child"), atomically: true, encoding: .utf8)
            text = "\u{FEFF}config-file = child\n" + text
            expectedSize = 18
        default:
            try "\u{FEFF}font-size = 18\n".write(to: directory.appendingPathComponent("child"), atomically: true, encoding: .utf8)
            text += "config-file = child\n"
            expectedSize = 18
        }
        try text.write(to: root, atomically: true, encoding: .utf8)
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, root.path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        var nativeSize: Float = 0
        #expect(ghostty_config_get(config, &nativeSize, "font-size", 9))
        #expect(nativeSize == expectedSize)
        let exported = GhosttyConfigReader.portableConfig(paths: [root.path])
        #expect(exported.split(separator: "\n").last == "font-size = \(Int(nativeSize))")
        #expect(!exported.contains("config-file"))
        try exported.write(to: root, atomically: true, encoding: .utf8)
        let mobile = try #require(ghostty_config_new())
        defer { ghostty_config_free(mobile) }
        ghostty_config_load_file(mobile, root.path)
        ghostty_config_finalize(mobile)
        #expect(ghostty_config_diagnostics_count(mobile) == 0)
        var mobileSize: Float = 0
        #expect(ghostty_config_get(mobile, &mobileSize, "font-size", 9))
        #expect(mobileSize == nativeSize)
    }

    @Test func includedPathResetMatchesNativeGhosttyOrder() throws {
        #expect(ghostty_init(0, nil) == 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("config")
        try "font-size = 10\nconfig-file = child\n".write(to: root, atomically: true, encoding: .utf8)
        try "font-size = 16\nconfig-file =\nconfig-file = grandchild\n".write(
            to: directory.appendingPathComponent("child"), atomically: true, encoding: .utf8)
        try "font-size = 20\n".write(to: directory.appendingPathComponent("grandchild"), atomically: true, encoding: .utf8)
        let config = try #require(ghostty_config_new())
        defer { ghostty_config_free(config) }
        ghostty_config_load_file(config, root.path)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        #expect(ghostty_config_diagnostics_count(config) == 0)
        var nativeSize: Float = 0
        #expect(ghostty_config_get(config, &nativeSize, "font-size", 9))
        #expect(nativeSize == 16)
        let exported = GhosttyConfigReader.portableConfig(paths: [root.path])
        #expect(exported.split(separator: "\n").last == "font-size = \(Int(nativeSize))")
    }

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
