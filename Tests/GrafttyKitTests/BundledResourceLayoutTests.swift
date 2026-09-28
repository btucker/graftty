import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec CONFIG-2.7: If GrafttyKit's resource bundle uses either SwiftPM's flat \
layout or the standard macOS `Contents/Resources` layout produced by Swift 6.4's \
build system, then the application shall locate the bundled web client assets, \
agent plugin payload, and vendored ghostty runtime resources.
""")
struct BundledResourceLayoutTests {
    private enum Layout { case flat, standard }

    /// Mirrors what `.copy("Web/Resources")`, `.copy("AgentPlugins")`, and
    /// `.copy("GhosttyResources/ghostty")` produce: a directory literally
    /// named `Resources` holding the web client, beside the other payloads.
    private func makeBundle(_ layout: Layout) throws -> Bundle {
        let fm = FileManager.default
        let root = try makeTempDir(prefix: "BundleLayout")
            .appendingPathComponent(GrafttyKitResourceBundle.bundleName)
        let resources: URL
        switch layout {
        case .flat:
            resources = root
        case .standard:
            resources = root.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let info = ["CFBundleIdentifier": "test.\(UUID().uuidString)", "CFBundlePackageType": "BNDL"]
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: root.appendingPathComponent("Contents/Info.plist"))
        }
        let web = resources.appendingPathComponent("Resources")
        try fm.createDirectory(at: web, withIntermediateDirectories: true)
        for name in ["index.html", "app.js", "app.css"] {
            try Data(name.utf8).write(to: web.appendingPathComponent(name))
        }
        for directory in ["AgentPlugins/claude", "ghostty/shell-integration"] {
            try fm.createDirectory(
                at: resources.appendingPathComponent(directory),
                withIntermediateDirectories: true
            )
        }
        return try #require(Bundle(url: root))
    }

    @Test(arguments: [Layout.flat, .standard])
    private func webAssetsResolve(_ layout: Layout) throws {
        let bundle = try makeBundle(layout)
        for (path, body) in [("/", "index.html"), ("/app.js", "app.js"), ("/app.css", "app.css")] {
            let asset = try WebStaticResources.asset(for: path, in: bundle)
            #expect(asset.data == Data(body.utf8))
        }
    }

    @Test(arguments: [Layout.flat, .standard])
    private func agentPluginsResolve(_ layout: Layout) throws {
        let bundle = try makeBundle(layout)
        let root = try #require(AgentPluginInstaller.bundledResourceRoot(bundle: bundle))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("claude").path))
    }

    @Test(arguments: [Layout.flat, .standard])
    private func ghosttyResourcesResolve(_ layout: Layout) throws {
        let bundle = try makeBundle(layout)
        let ghostty = try #require(GhosttyRuntimeResources.bundledResourcesDir(bundle: bundle))
        #expect(FileManager.default.fileExists(
            atPath: ghostty.appendingPathComponent("shell-integration").path
        ))
    }
}
