import Foundation
import Testing

@Suite("@spec TECH-6.1: If an iOS CI test shard loses its selected simulator before testing begins, then the workflow shall create and boot a replacement simulator and retry `xcodebuild` exactly once. The workflow shall not retry ordinary build or test failures.")
struct IOSTestShardRunnerTests {
    @Test("recreates a simulator that disappears during destination resolution")
    func retriesMissingSimulatorOnce() throws {
        let result = try runFixture(firstExitCode: 70, removeSimulator: true)

        #expect(result.exitCode == 0)
        #expect(result.xcodebuildAttempts == 2)
        #expect(result.simulatorsCreated == 2)
    }

    @Test("does not retry an ordinary xcodebuild failure")
    func preservesOrdinaryFailure() throws {
        let result = try runFixture(firstExitCode: 65, removeSimulator: false)

        #expect(result.exitCode == 65)
        #expect(result.xcodebuildAttempts == 1)
        #expect(result.simulatorsCreated == 1)
    }

    @Test("limits missing-simulator recovery to one retry")
    func retriesOnlyOnce() throws {
        let result = try runFixture(
            firstExitCode: 70,
            removeSimulator: true,
            secondExitCode: 70
        )

        #expect(result.exitCode == 70)
        #expect(result.xcodebuildAttempts == 2)
        #expect(result.simulatorsCreated == 2)
    }

    private func runFixture(
        firstExitCode: Int32,
        removeSimulator: Bool,
        secondExitCode: Int32 = 0
    ) throws -> FixtureResult {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("graftty-ios-shard-runner-\(UUID().uuidString)")
        let fakeBin = root.appendingPathComponent("bin")
        let state = root.appendingPathComponent("state")
        let products = root.appendingPathComponent(".derivedData/Build/Products")
        try fileManager.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: state, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: products, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Data().write(to: products.appendingPathComponent("Fixture.xctestrun"))
        try "sim-1\n".write(
            to: state.appendingPathComponent("current"),
            atomically: true,
            encoding: .utf8
        )
        try "1\n".write(
            to: state.appendingPathComponent("create-count"),
            atomically: true,
            encoding: .utf8
        )
        try Data().write(to: state.appendingPathComponent("device-sim-1"))

        try writeExecutable(
            to: fakeBin.appendingPathComponent("xcrun"),
            contents: Self.fakeXcrun
        )
        try writeExecutable(
            to: fakeBin.appendingPathComponent("xcodebuild"),
            contents: Self.fakeXcodebuild
        )

        let process = Process()
        process.executableURL = Self.scriptURL
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(fakeBin.path):\(environment["PATH"] ?? "")"
        environment["FAKE_STATE"] = state.path
        environment["FAKE_FIRST_EXIT"] = String(firstExitCode)
        environment["FAKE_SECOND_EXIT"] = String(secondExitCode)
        environment["FAKE_REMOVE_SIMULATOR"] = removeSimulator ? "1" : "0"
        environment["GITHUB_ENV"] = root.appendingPathComponent("github-env").path
        environment["SHARD_NAME"] = "fixture"
        environment["SIMULATOR_UDID"] = "sim-1"
        environment["TEST_ARGUMENTS"] = "-only-testing:FixtureTests"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        return FixtureResult(
            exitCode: process.terminationStatus,
            xcodebuildAttempts: try integer(
                at: state.appendingPathComponent("xcodebuild-count")
            ),
            simulatorsCreated: try integer(
                at: state.appendingPathComponent("create-count")
            )
        )
    }

    private func writeExecutable(to url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func integer(at url: URL) throws -> Int {
        let text = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int(text))
    }

    private static let scriptURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/run-ios-test-shard.sh")

    private static let fakeXcrun = #"""
    #!/bin/bash
    set -euo pipefail
    case "${1:-} ${2:-}" in
      "simctl list")
        current="$(cat "$FAKE_STATE/current")"
        if [[ -e "$FAKE_STATE/device-$current" ]]; then
          echo "    Graftty CI ($current) ($current) (Booted)"
        fi
        ;;
      "simctl create")
        count="$(( $(cat "$FAKE_STATE/create-count") + 1 ))"
        echo "$count" > "$FAKE_STATE/create-count"
        current="sim-$count"
        echo "$current" > "$FAKE_STATE/current"
        touch "$FAKE_STATE/device-$current"
        echo "$current"
        ;;
      "simctl boot"|"simctl bootstatus")
        ;;
      "simctl shutdown"|"simctl delete")
        current="${3:-}"
        rm -f "$FAKE_STATE/device-$current"
        ;;
      *)
        echo "unexpected xcrun arguments: $*" >&2
        exit 2
        ;;
    esac
    """#

    private static let fakeXcodebuild = #"""
    #!/bin/bash
    set -euo pipefail
    count=0
    if [[ -e "$FAKE_STATE/xcodebuild-count" ]]; then
      count="$(cat "$FAKE_STATE/xcodebuild-count")"
    fi
    count="$((count + 1))"
    echo "$count" > "$FAKE_STATE/xcodebuild-count"
    if [[ "$count" -eq 1 ]]; then
      if [[ "$FAKE_REMOVE_SIMULATOR" == "1" ]]; then
        current="$(cat "$FAKE_STATE/current")"
        rm -f "$FAKE_STATE/device-$current"
      fi
      exit "$FAKE_FIRST_EXIT"
    fi
    exit "$FAKE_SECOND_EXIT"
    """#
}

private struct FixtureResult {
    let exitCode: Int32
    let xcodebuildAttempts: Int
    let simulatorsCreated: Int
}
