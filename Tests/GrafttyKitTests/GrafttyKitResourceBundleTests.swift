import Foundation
import Testing
@testable import GrafttyKit

@Suite("""
@spec CONFIG-2.6: The application shall resolve GrafttyKit's SwiftPM resource \
bundle from the packaged `.app` layout (`Contents/Resources/`), falling back to \
`Bundle.module` only for `swift test`/`swift run`, so a distributed app does not \
trap on SwiftPM's generated accessor (which probes only the `.app` root and the \
compiling machine's `.build` path — neither present once shipped).
""")
struct GrafttyKitResourceBundleTests {
    /// Build a throwaway `.app`-like tree with the resource bundle at the given
    /// subpath relative to the `.app` root, returning (appRoot, resourcesDir).
    private func makeApp(
        bundleUnder relative: String?
    ) throws -> (appRoot: URL, resourcesDir: URL) {
        let fm = FileManager.default
        let appRoot = try makeTempDir(prefix: "ResBundleTest").appendingPathComponent("App.app")
        let resourcesDir = appRoot.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        if let relative {
            // Lay down a recognizable payload so the bundle isn't empty.
            let bundleDir = appRoot.appendingPathComponent(relative)
                .appendingPathComponent(GrafttyKitResourceBundle.bundleName)
            try fm.createDirectory(
                at: bundleDir.appendingPathComponent("ghostty/shell-integration/zsh"),
                withIntermediateDirectories: true
            )
            try Data().write(
                to: bundleDir.appendingPathComponent("ghostty/shell-integration/zsh/.zshenv")
            )
        }
        return (appRoot, resourcesDir)
    }

    /// A sentinel bundle distinct from any candidate, so we can assert the
    /// resolver did NOT fall through to `Bundle.module`.
    private func sentinelBundle() throws -> Bundle {
        try #require(Bundle(url: makeTempDir(prefix: "Sentinel")))
    }

    @Test("Packaged layout: resolves the bundle under Contents/Resources, not the fallback")
    func prefersContentsResources() throws {
        let (appRoot, resourcesDir) = try makeApp(bundleUnder: "Contents/Resources")
        let sentinel = try sentinelBundle()

        let resolved = GrafttyKitResourceBundle.resolve(
            mainResourceURL: resourcesDir,
            mainBundleURL: appRoot,
            moduleFallback: { sentinel }
        )

        let expected = resourcesDir.appendingPathComponent(GrafttyKitResourceBundle.bundleName)
        #expect(resolved.bundleURL.standardizedFileURL == expected.standardizedFileURL)
        // And the vendored ghostty payload resolves through it.
        let ghostty = try #require(GhosttyRuntimeResources.bundledResourcesDir(bundle: resolved))
        #expect(FileManager.default.fileExists(
            atPath: ghostty.appendingPathComponent("shell-integration/zsh/.zshenv").path
        ))
    }

    @Test("Flat/CLI layout: falls back to the main bundle root when Resources lacks it")
    func fallsBackToBundleRoot() throws {
        // Bundle sits at the .app root (next to the executable), not in Resources.
        let (appRoot, resourcesDir) = try makeApp(bundleUnder: ".")
        let sentinel = try sentinelBundle()

        let resolved = GrafttyKitResourceBundle.resolve(
            mainResourceURL: resourcesDir,
            mainBundleURL: appRoot,
            moduleFallback: { sentinel }
        )

        let expected = appRoot.appendingPathComponent(GrafttyKitResourceBundle.bundleName)
        #expect(resolved.bundleURL.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test("Neither location has it: uses the Bundle.module fallback")
    func usesModuleFallbackWhenAbsent() throws {
        let (appRoot, resourcesDir) = try makeApp(bundleUnder: nil)
        let sentinel = try sentinelBundle()

        let resolved = GrafttyKitResourceBundle.resolve(
            mainResourceURL: resourcesDir,
            mainBundleURL: appRoot,
            moduleFallback: { sentinel }
        )

        #expect(resolved.bundleURL.standardizedFileURL == sentinel.bundleURL.standardizedFileURL)
    }
}
