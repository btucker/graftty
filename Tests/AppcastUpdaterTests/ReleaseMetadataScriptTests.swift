import Foundation
import Testing

@Suite("Release metadata script")
struct ReleaseMetadataScriptTests {
    @Test("""
    @spec UPDATE-3.4: When the release workflow processes a version tag, the application shall assign suffixed versions to the `prerelease` appcast channel and stable versions to the default channel, then derive a numeric build version that increases with both the GitHub run number and each run attempt.
    """)
    func classifiesStableAndPrereleaseVersions() throws {
        let prerelease = try metadata(version: "0.6.0-beta.2", runNumber: "41")
        let stable = try metadata(version: "0.6.0", runNumber: "42")

        #expect(prerelease["version"] == "0.6.0-beta.2")
        #expect(prerelease["build_version"] == "100.41.00")
        #expect(prerelease["prerelease"] == "true")
        #expect(prerelease["channel"] == "prerelease")

        #expect(stable["version"] == "0.6.0")
        #expect(stable["build_version"] == "100.42.00")
        #expect(stable["prerelease"] == "false")
        #expect(stable["channel"] == "")
    }

    @Test func buildMetadataDoesNotMakeAStableVersionPrerelease() throws {
        let metadata = try metadata(version: "0.6.0+notarized.1", runNumber: "43")
        #expect(metadata["prerelease"] == "false")
        #expect(metadata["channel"] == "")
    }

    @Test func rerunGetsANewBuildVersion() throws {
        let first = try metadata(version: "0.6.0-beta.2", runNumber: "41", runAttempt: "1")
        let rerun = try metadata(version: "0.6.0-beta.2", runNumber: "41", runAttempt: "2")
        #expect(first["build_version"] == "100.41.00")
        #expect(rerun["build_version"] == "100.41.01")
    }

    private func metadata(
        version: String,
        runNumber: String,
        runAttempt: String = "1"
    ) throws -> [String: String] {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.scriptURL.path, version, runNumber, runAttempt]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let error = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        try #require(process.terminationStatus == 0, Comment(rawValue: error))

        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let separator = try #require(line.firstIndex(of: "="))
            result[String(line[..<separator])] = String(line[line.index(after: separator)...])
        }
        return result
    }

    private static var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/release-metadata.sh")
    }
}
