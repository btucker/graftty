import Testing
import Foundation
@testable import GrafttyKit

@Suite("CLIInstaller Tests")
struct CLIInstallerTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-cli-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writableParentPlansDirectSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A real file so the source-exists check passes. Content
        // doesn't matter — plan only checks existence.
        let source = dir.appendingPathComponent("graftty-src").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: source))
        let destination = dir.appendingPathComponent("graftty").path

        let plan = CLIInstaller.plan(source: source, destination: destination)
        #expect(plan == .directSymlink(source: source, destination: destination))
    }

    @Test func unwritableParentPlansSudoCommand() throws {
        // /usr/local/bin is root:wheel 755 — unwritable as a normal user.
        // Skip if /usr/local/bin happens to be writable (unusual, but some
        // devs run with broadened perms).
        guard !FileManager.default.isWritableFile(atPath: "/usr/local/bin") else {
            return
        }

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("graftty-src").path
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: source))
        let destination = "/usr/local/bin/graftty"

        let plan = CLIInstaller.plan(source: source, destination: destination)

        guard case .showSudoCommand(let command, let dest) = plan else {
            Issue.record("Expected .showSudoCommand plan for /usr/local/bin, got \(plan)")
            return
        }
        #expect(dest == destination)
        #expect(command.contains("sudo"))
        #expect(command.contains("ln -sf"))
        #expect(command.contains(source))
        #expect(command.contains("/usr/local/bin/graftty"))
    }

    @Test func sudoCommandWrapsPathsInSingleQuotes() {
        let cmd = CLIInstaller.sudoSymlinkCommand(
            source: "/Applications/Graftty.app/Contents/Helpers/graftty",
            destination: "/usr/local/bin/graftty"
        )
        #expect(cmd == "sudo ln -sf '/Applications/Graftty.app/Contents/Helpers/graftty' '/usr/local/bin/graftty'")
    }

    @Test func sudoCommandEscapesEmbeddedSingleQuotes() {
        // If someone renamed their app bundle to contain a single quote,
        // naive 'x' quoting would break. We use the closing-quote trick:
        // 'it's' -> 'it'"'"'s'
        let cmd = CLIInstaller.sudoSymlinkCommand(
            source: "/Applications/It's Graftty.app/Contents/Helpers/graftty",
            destination: "/usr/local/bin/graftty"
        )
        // The source should be: 'It'"'"'s Graftty.app'
        #expect(cmd.contains(#"'/Applications/It'"'"'s Graftty.app/Contents/Helpers/graftty'"#))
    }

    /// When the bundled CLI binary doesn't exist — e.g. the user is
    /// running a raw `swift run`-built Graftty that hasn't been put
    /// through `scripts/bundle.sh` — `plan` currently happily returns
    /// `.directSymlink`, and the GUI proceeds to `createSymbolicLink`
    /// pointing at a non-existent file. `ln -s` doesn't verify the
    /// target, so `/usr/local/bin/graftty` then resolves to nothing
    /// and every future `graftty notify` fails with
    /// "command not found" at the shell level.
    ///
    /// Pin the failure mode: plan must return `.sourceMissing` so the
    /// GUI can surface an actionable error instead of silently creating
    /// a dangling link.
    @Test func missingSourcePlansSourceMissing() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("nonexistent-graftty").path
        let destination = dir.appendingPathComponent("graftty").path

        let plan = CLIInstaller.plan(source: source, destination: destination)
        #expect(plan == .sourceMissing(source: source))
    }

    @Test func sudoCommandIsValidShellWhenExecuted() throws {
        // A round-trip sanity check: feed our generated command (without
        // actually running the sudo ln) into /bin/sh with `echo` prefixed
        // instead, to verify the quoting yields the expected two arguments.
        let source = "/tmp/path with spaces/graftty"
        let destination = "/tmp/symlink"
        let cmd = CLIInstaller.sudoSymlinkCommand(source: source, destination: destination)

        // Replace `sudo ln -sf` with `printf '%s\n%s\n'` to capture args.
        let probedCommand = cmd.replacingOccurrences(of: "sudo ln -sf", with: "printf '%s\\n%s\\n'")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", probedCommand]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let args = output.split(separator: "\n").map(String.init)
        #expect(args == [source, destination])
    }
}
