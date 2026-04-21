import Testing
import Foundation
@testable import GrafttyKit

@Suite("GhosttyConfigLocator Tests")
struct GhosttyConfigLocatorTests {

    /// Creates a fresh tmp directory that stands in for `$HOME` so the
    /// real user's Ghostty config is never touched by these tests.
    private func makeFakeHome() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-cfg-locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Given no existing config anywhere, the locator returns the macOS
    /// default path (inside `Library/Application Support/com.mitchellh.ghostty/`)
    /// so the GUI has a concrete file URL to `NSWorkspace.open` after
    /// creating it. No file is created by `resolveURL` itself.
    @Test func emptyHomeReturnsMacOSDefault() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let url = GhosttyConfigLocator.resolveURL(home: home, environment: [:])

        let expected = home.appendingPathComponent(GhosttyConfigLocator.macOSDefaultRelativePath)
        #expect(url.path == expected.path)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// When `~/.config/ghostty/config` exists, the locator picks it —
    /// this is the XDG-standard path Ghostty loads via
    /// `ghostty_config_load_default_files`, so "open" matches "load".
    @Test func xdgDefaultPathWinsWhenPresent() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let xdg = home.appendingPathComponent(".config/ghostty/config")
        try FileManager.default.createDirectory(
            at: xdg.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: xdg.path, contents: Data())

        let url = GhosttyConfigLocator.resolveURL(home: home, environment: [:])
        #expect(url.path == xdg.path)
    }

    /// An explicit `$XDG_CONFIG_HOME` overrides `~/.config` — same rule
    /// Ghostty itself uses for config discovery.
    @Test func explicitXDGConfigHomeOverridesDotConfig() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let xdgHome = home.appendingPathComponent("xdg")
        let xdgCfg = xdgHome.appendingPathComponent("ghostty/config")
        try FileManager.default.createDirectory(
            at: xdgCfg.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: xdgCfg.path, contents: Data())

        // Populate `~/.config/ghostty/config` too to confirm XDG wins.
        let dotConfig = home.appendingPathComponent(".config/ghostty/config")
        try FileManager.default.createDirectory(
            at: dotConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: dotConfig.path, contents: Data())

        let url = GhosttyConfigLocator.resolveURL(
            home: home,
            environment: ["XDG_CONFIG_HOME": xdgHome.path]
        )
        #expect(url.path == xdgCfg.path)
    }

    /// An empty `$XDG_CONFIG_HOME` is treated as unset (POSIX convention):
    /// fall through to `~/.config/ghostty/config`.
    @Test func emptyXDGConfigHomeIsIgnored() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let dotConfig = home.appendingPathComponent(".config/ghostty/config")
        try FileManager.default.createDirectory(
            at: dotConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: dotConfig.path, contents: Data())

        let url = GhosttyConfigLocator.resolveURL(
            home: home,
            environment: ["XDG_CONFIG_HOME": ""]
        )
        #expect(url.path == dotConfig.path)
    }

    /// If neither XDG path exists but Ghostty-macOS's App Support file
    /// does, that wins over the never-created default.
    @Test func macOSAppSupportPathWinsWhenOnlyItExists() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let macOS = home.appendingPathComponent(GhosttyConfigLocator.macOSDefaultRelativePath)
        try FileManager.default.createDirectory(
            at: macOS.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: macOS.path, contents: Data())

        let url = GhosttyConfigLocator.resolveURL(home: home, environment: [:])
        #expect(url.path == macOS.path)
    }

    /// `ensureExists` creates the file (and its parent chain) only when
    /// missing. Pre-existing content is never overwritten.
    @Test func ensureExistsCreatesFileAndParentsWhenMissing() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let target = home.appendingPathComponent(GhosttyConfigLocator.macOSDefaultRelativePath)
        #expect(!FileManager.default.fileExists(atPath: target.path))

        try GhosttyConfigLocator.ensureExists(at: target)

        #expect(FileManager.default.fileExists(atPath: target.path))
        let data = try Data(contentsOf: target)
        #expect(data.isEmpty)
    }

    @Test func ensureExistsIsNoOpWhenAlreadyPresent() throws {
        let home = try makeFakeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let target = home.appendingPathComponent(GhosttyConfigLocator.macOSDefaultRelativePath)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let payload = Data("font-family = Monaco\n".utf8)
        try payload.write(to: target)

        try GhosttyConfigLocator.ensureExists(at: target)

        // Round-trip: our pre-written contents are still there, untouched.
        #expect(try Data(contentsOf: target) == payload)
    }
}
