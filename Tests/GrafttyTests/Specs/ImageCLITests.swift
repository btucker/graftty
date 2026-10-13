import Foundation
import Testing
@testable import GrafttyCLI
import GrafttyKit

struct ImageCLITests {
    @MainActor
    @Test("@spec IMAGE-1.1: When graftty image runs without a terminal, the CLI shall send an absolute file path and the originating pane session through app IPC without emitting image bytes, terminal escapes, or padding, and shall propagate rejection and transport failures.", .timeLimit(.minutes(1)))
    func sendsImageRequestWithoutTTY() async throws {
        let executable = try imageExecutable()
        let root = URL(fileURLWithPath: "/tmp/graftty-image-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = root.appendingPathComponent("s").path
        let target = root.appendingPathComponent("chart with spaces.png").path
        let server = SocketServer(socketPath: socket)
        defer { server.stop() }
        for response in [ResponseMessage.ok, .error("Image rejected")] {
            var received: NotificationMessage?
            server.onRequest = { message in received = message; return response }
            try server.start()
            let result = try await runImage(executable: executable, target: target, socket: socket)
            #expect(received == .previewImage(path: "", target: target, paneSessionName: "fixture-pane"))
            #expect(result.stdout.isEmpty)
            #expect(result.status == (response == .ok ? 0 : 1))
            #expect(response == .ok ? result.stderr.isEmpty : result.stderr.contains("Image rejected"))
            server.stop()
        }
        let result = try await runImage(executable: executable, target: target, socket: root.appendingPathComponent("missing").path)
        #expect(result.status != 0)
        #expect(result.stdout.isEmpty)
    }

    @Test("@spec IMAGE-1.2: When graftty image receives legacy width and pad options, the CLI shall accept them without reserving terminal rows, and shall encode a response-bearing native preview request.")
    func acceptsLegacyFlagsAndCodesRequest() throws {
        let command = try Image.parse(["./chart.png", "--width", "40", "--pad", "12"])
        #expect(command.path == "./chart.png")
        let message = NotificationMessage.previewImage(path: "/project", target: "/tmp/chart.png", paneSessionName: "pane")
        #expect(message.expectsResponse)
        #expect(try JSONDecoder().decode(NotificationMessage.self, from: JSONEncoder().encode(message)) == message)
    }
    private func imageExecutable() throws -> URL {
        // Swift Testing can run inside a separate runner, so Bundle.main is
        // not necessarily the package's test bundle or product directory.
        let locations = [Bundle(for: ImageCLITestBundleAnchor.self).bundleURL,
                         URL(fileURLWithPath: CommandLine.arguments[0])]
        for location in locations {
            var directory = location.deletingLastPathComponent()
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("graftty-cli")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        throw NSError(domain: "ImageCLITests", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "The package's graftty-cli executable must be built beside its test bundle."])
    }

    @MainActor
    private func runImage(executable: URL, target: String, socket: String) async throws
        -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["image", target, "--width", "40", "--pad", "12"]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_SOCK"] = socket
        environment["ZMX_SESSION"] = "fixture-pane"
        process.environment = environment
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now + .seconds(8)
        while process.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(!process.isRunning, "The isolated open command did not finish before its deadline")
        return (process.terminationStatus,
                String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

}

private final class ImageCLITestBundleAnchor: NSObject {}
