import Foundation
import Testing
@testable import GrafttyCommandUI

@Suite("@spec CONFIG-2.8: When provider marks are loaded in a packaged application, the application shall resolve their shipped resource bundle without accessing the build machine's bundle path, and shall fall back to a terminal icon if that bundle is missing.")
struct CommandUIResourceBundleTests {
    @Test(arguments: ["Contents/Resources", "."])
    func packagedProviderMarks(_ relative: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Graftty.app")
        let resources = app.appendingPathComponent("Contents/Resources")
        let destination = app.appendingPathComponent(relative).appendingPathComponent(CommandUIResourceBundle.bundleName)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try #require(CommandUIResourceBundle.bundle)
        try FileManager.default.copyItem(at: original.bundleURL, to: destination)
        var fallbackCalled = false
        let resolved = try #require(CommandUIResourceBundle.resolve(mainResourceURL: resources, mainBundleURL: app) {
            fallbackCalled = true
            return original
        })
        #expect(!fallbackCalled)
        #expect(resolved.bundleURL.standardizedFileURL == destination.standardizedFileURL)
        for name in ["claude", "codex"] {
            #expect(resolved.url(forResource: name, withExtension: "png") != nil)
        }
    }

    @Test func missingPackagedBundleDoesNotCallTrappingAccessor() throws {
        var fallbackCalled = false
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        let result = CommandUIResourceBundle.resolve(mainResourceURL: missing.appendingPathComponent("Contents/Resources"),
            mainBundleURL: missing) {
            fallbackCalled = true
            return Bundle.main
        }
        #expect(result == nil)
        #expect(!fallbackCalled)
    }

    @Test func developmentBuildUsesModuleBundle() {
        var fallbackCalled = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let result = CommandUIResourceBundle.resolve(mainResourceURL: nil, mainBundleURL: root) {
            fallbackCalled = true
            return Bundle.main
        }
        #expect(fallbackCalled)
        #expect(result == Bundle.main)
    }

    @Test func packagingCopiesProviderResourceBundle() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "for b in ")?.lowerBound)
        let end = try #require(script.range(of: "\ndone", range: start..<script.endIndex)?.upperBound)
        let loop = String(script[start..<end])
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let products = temporary.appendingPathComponent("products")
        let resources = temporary.appendingPathComponent("Graftty.app/Contents/Resources")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: #require(CommandUIResourceBundle.bundle).bundleURL,
            to: products.appendingPathComponent(CommandUIResourceBundle.bundleName))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", loop]
        process.environment = ["PATH": "/usr/bin:/bin", "BIN_DIR": products.path,
            "APP": temporary.appendingPathComponent("Graftty.app").path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(FileManager.default.fileExists(atPath: resources.appendingPathComponent(CommandUIResourceBundle.bundleName).path))
    }
}
