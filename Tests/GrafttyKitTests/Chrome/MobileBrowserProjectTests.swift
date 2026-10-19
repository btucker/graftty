import Foundation
import Testing

#if os(macOS)
@Suite("Mobile browser project generation")
struct MobileBrowserProjectTests {
    private static var generator: String? {
        ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    @Test("@spec CHROME-5.1: When the iOS project is regenerated, the application shall place Chrome rendering tests only in the foreground browser test host and retain ordinary session tests in the unhosted unit bundle.", .enabled(if: generator != nil))
    func regeneratedProjectHostsBrowserRenderingTests() throws {
        let fixture = try generateFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let data = try run("/usr/bin/plutil", ["-convert", "json", "-o", "-", fixture.appendingPathComponent("Apps/GrafttyMobile/GrafttyMobile.xcodeproj/project.pbxproj").path])
        let project = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let objects = try #require(project["objects"] as? [String: [String: Any]])
        let hosted = try target("GrafttyMobileBrowserTests", in: objects)
        let ordinary = try target("GrafttyMobileKitTests", in: objects)
        #expect(try sourceNames(hosted, in: objects).filter { $0 == "ChromeTabViewerTests.swift" }.count == 1)
        #expect(try sourceNames(hosted, in: objects).contains("HostBrowserProxyTests.swift"))
        #expect(try !sourceNames(ordinary, in: objects).contains("ChromeTabViewerTests.swift"))
        #expect(try sourceNames(ordinary, in: objects).contains("LocalBrowserSessionTests.swift"))
        let configurationList = try #require(hosted["buildConfigurationList"] as? String)
        let list = try #require(objects[configurationList])
        let configurations = try #require(list["buildConfigurations"] as? [String])
        for configuration in configurations {
            let settings = try #require(objects[configuration]?["buildSettings"] as? [String: Any])
            #expect((settings["TEST_HOST"] as? String)?.contains("GrafttyMobileTestHost.app") == true)
        }
    }

    @Test("@spec CHROME-5.2: When the browser test host metadata is regenerated, the application shall retain its launch-screen declaration so native keyboard and viewport tests use modern scene geometry.", .enabled(if: generator != nil))
    func regeneratedBrowserHostPreservesModernGeometry() throws {
        let fixture = try generateFixture()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let data = try Data(contentsOf: fixture.appendingPathComponent("Apps/GrafttyMobile/GrafttyMobileTestHost/Info.plist"))
        let metadata = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(metadata["UILaunchScreen"] as? [String: Any] != nil)
    }

    private func generateFixture() throws -> URL {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-browser-project-\(UUID())")
        do {
            for path in ["Apps/GrafttyMobile/project.yml", "Apps/GrafttyMobile/GrafttyMobileTestHost/Info.plist", "Apps/GrafttyMobile/GrafttyMobile/Info.plist"] {
                let destination = fixture.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: repository.appendingPathComponent(path), to: destination)
            }
            for path in ["Apps/GrafttyMobile/GrafttyMobile/GrafttyMobileApp.swift", "Apps/GrafttyMobile/GrafttyMobileTestHost/GrafttyMobileTestHost.swift", "Tests/GrafttyMobileKitTests/UI/ChromeTabViewerTests.swift", "Tests/GrafttyMobileKitTests/UI/HostBrowserProxyTests.swift", "Tests/GrafttyMobileKitTests/UI/RemoteBrowserButtonTests.swift", "Tests/GrafttyMobileKitTests/UI/WorktreeRowAlignmentTests.swift", "Tests/GrafttyMobileInteractionTests/BrowserControlInteractionTests.swift", "Tests/GrafttyTests/AgentIntegration/AgentIntegrationWire.swift", "Tests/GrafttyMobileKitTests/Session/LocalBrowserSessionTests.swift", "Tests/GrafttyRemoteClientTests/Placeholder.swift", "Package.swift"] {
                let destination = fixture.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "// Project-generation fixture\n".write(to: destination, atomically: true, encoding: .utf8)
            }
            _ = try run(try #require(Self.generator), ["generate", "--spec", fixture.appendingPathComponent("Apps/GrafttyMobile/project.yml").path])
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: fixture)
            throw error
        }
    }

    private func target(_ name: String, in objects: [String: [String: Any]]) throws -> [String: Any] {
        try #require(objects.values.first { $0["isa"] as? String == "PBXNativeTarget" && $0["name"] as? String == name })
    }

    private func sourceNames(_ target: [String: Any], in objects: [String: [String: Any]]) throws -> [String] {
        let phases = try #require(target["buildPhases"] as? [String])
        let sources = try #require(phases.compactMap { objects[$0] }.first { $0["isa"] as? String == "PBXSourcesBuildPhase" })
        return try #require(sources["files"] as? [String]).compactMap { file in
            guard let reference = objects[file]?["fileRef"] as? String,
                  let path = objects[reference]?["path"] as? String else { return nil }
            return (path as NSString).lastPathComponent
        }
    }

    private func run(_ command: String, _ arguments: [String]) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "\(String(decoding: data, as: UTF8.self))")
        return data
    }
}
#endif
