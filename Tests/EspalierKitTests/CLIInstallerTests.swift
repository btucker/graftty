import Testing
import Foundation
@testable import EspalierKit

@Suite("CLIInstaller Tests")
struct CLIInstallerTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("espalier-cli-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writableParentPlansDirectSymlink() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = "/Applications/Espalier.app/Contents/Helpers/espalier"
        let destination = dir.appendingPathComponent("espalier").path

        let plan = CLIInstaller.plan(source: source, destination: destination)
        #expect(plan == .directSymlink(source: source, destination: destination))
    }

    @Test func unwritableParentPlansSudoCommand() {
        // /usr/local/bin is root:wheel 755 — unwritable as a normal user.
        // Skip if /usr/local/bin happens to be writable (unusual, but some
        // devs run with broadened perms).
        guard !FileManager.default.isWritableFile(atPath: "/usr/local/bin") else {
            return
        }

        let source = "/Applications/Espalier.app/Contents/Helpers/espalier"
        let destination = "/usr/local/bin/espalier"

        let plan = CLIInstaller.plan(source: source, destination: destination)

        guard case .showSudoCommand(let command, let dest) = plan else {
            Issue.record("Expected .showSudoCommand plan for /usr/local/bin, got \(plan)")
            return
        }
        #expect(dest == destination)
        #expect(command.contains("sudo"))
        #expect(command.contains("ln -sf"))
        #expect(command.contains("/Applications/Espalier.app/Contents/Helpers/espalier"))
        #expect(command.contains("/usr/local/bin/espalier"))
    }

    @Test func sudoCommandWrapsPathsInSingleQuotes() {
        let cmd = CLIInstaller.sudoSymlinkCommand(
            source: "/Applications/Espalier.app/Contents/Helpers/espalier",
            destination: "/usr/local/bin/espalier"
        )
        #expect(cmd == "sudo ln -sf '/Applications/Espalier.app/Contents/Helpers/espalier' '/usr/local/bin/espalier'")
    }

    @Test func sudoCommandEscapesEmbeddedSingleQuotes() {
        // If someone renamed their app bundle to contain a single quote,
        // naive 'x' quoting would break. We use the closing-quote trick:
        // 'it's' -> 'it'"'"'s'
        let cmd = CLIInstaller.sudoSymlinkCommand(
            source: "/Applications/It's Espalier.app/Contents/Helpers/espalier",
            destination: "/usr/local/bin/espalier"
        )
        // The source should be: 'It'"'"'s Espalier.app'
        #expect(cmd.contains(#"'/Applications/It'"'"'s Espalier.app/Contents/Helpers/espalier'"#))
    }

    @Test func sudoCommandIsValidShellWhenExecuted() throws {
        // A round-trip sanity check: feed our generated command (without
        // actually running the sudo ln) into /bin/sh with `echo` prefixed
        // instead, to verify the quoting yields the expected two arguments.
        let source = "/tmp/path with spaces/espalier"
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
