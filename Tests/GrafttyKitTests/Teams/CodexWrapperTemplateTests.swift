import Foundation
import Testing
@testable import GrafttyKit
import GrafttyTestSupport

@Suite("Codex wrapper shell template")
struct CodexWrapperTemplateTests {
    @Test("Native flock keeps administration exclusively locked", .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/flock")))
    func nativeFlockHoldsExclusiveAdministrationLock() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let durable = root.appendingPathComponent("durable")
        let bin = root.appendingPathComponent("bin")
        for directory in [managed, durable, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let lock = managed.appendingPathComponent(".graftty-mirror.lock")
        try Data().write(to: lock)
        let codex = bin.appendingPathComponent("codex")
        try """
            #!/bin/sh
            # A shared probe must fail while administration owns an exclusive lock.
            if /usr/bin/flock -n -s "$GRAFTTY_TEST_LOCK" /bin/true; then exit 41; fi
            [ "$CODEX_HOME" = "$GRAFTTY_TEST_DURABLE" ] || exit 42
            """.write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        let script = try AgentHookInstaller.codexWrapperScript(
            wrapperDirectory: root.appendingPathComponent("wrapper-bin").path,
            grafttyCLIPath: "/bin/true",
            codexHomeDirectory: managed.path,
            codexSourceDirectory: durable.path
        )
        let wrapper = root.appendingPathComponent("wrapper.sh")
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path, "plugin", "list"]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin", "CODEX_HOME": managed.path,
            "GRAFTTY_DISABLE_AGENT_HOOKS": "1", "GRAFTTY_TEST_LOCK": lock.path,
            "GRAFTTY_TEST_DURABLE": durable.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(stderr.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    @Test("@spec TEAM-10.22: When Codex wrapper paths contain newlines or shell metacharacters, the application shall treat them as literal data in comments and missing-binary diagnostics without executing them.", arguments: [true, false])
    func pathsCannotExecuteShellText(inComment: Bool) throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let injected = root.appendingPathComponent("injected")
        let wrapperDirectory = inComment ? "/missing/wrapper" :
            "/missing/$(printf injected > \"$GRAFTTY_TEST_INJECTION\")/`printf injected > \"$GRAFTTY_TEST_INJECTION\"`/$GRAFTTY_TEST_INJECTION/'quoted'"
        let cli = inComment ? "/missing/graftty\nprintf injected > \"$GRAFTTY_TEST_INJECTION\"\n#" : "/missing/graftty"
        let script = try AgentHookInstaller.codexWrapperScript(
            wrapperDirectory: wrapperDirectory,
            grafttyCLIPath: cli,
            codexHomeDirectory: root.appendingPathComponent("home").path,
            codexSourceDirectory: root.appendingPathComponent("source").path
        )
        let wrapper = root.appendingPathComponent("wrapper.sh")
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [wrapper.path]
        process.environment = ["PATH": "/missing/binaries", "GRAFTTY_TEST_INJECTION": injected.path]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 127)
        #expect(!FileManager.default.fileExists(atPath: injected.path))
        #expect(diagnostic == "graftty: unable to find real codex outside \(wrapperDirectory)\n")
    }

    struct Inputs: CustomTestStringConvertible {
        var wrapperDirectory: String
        var grafttyCLIPath: String
        var codexHomeDirectory: String
        var codexSourceDirectory: String
        var codexLockCommandPath = "/usr/bin/lockf"

        var testDescription: String { wrapperDirectory }
    }

    static let inputs: [Inputs] = [
        Inputs(
            wrapperDirectory: "/app/hooks/bin",
            grafttyCLIPath: "/app/graftty",
            codexHomeDirectory: "/app/hooks/codex-home",
            codexSourceDirectory: "/Users/me/.codex"
        ),
        Inputs(
            wrapperDirectory: "/tmp/has $dollar/it's/bin",
            grafttyCLIPath: "/Applications/Graftty Beta.app/Contents/Helpers/graftty",
            codexHomeDirectory: "/tmp/has $dollar/it's/codex-home",
            codexSourceDirectory: "/tmp/back\\slash \"quoted\" `tick`/.codex",
            codexLockCommandPath: "/opt/lock tools/lockf"
        ),
        Inputs(
            wrapperDirectory: "/tmp/{{CODEX_HOME}}/bin",
            grafttyCLIPath: "/tmp/{{GRAFTTY_CLI}}\n{{VERSION}}/graftty",
            codexHomeDirectory: "/tmp/{{TUI_COMMAND}}/codex-home",
            codexSourceDirectory: "/tmp/{{CODEX_SOURCE}}/.codex",
            codexLockCommandPath: "{{LOCK_COMMAND}}"
        ),
    ]

    @Test("The template matches the frozen renderer with the reviewed #533 corrections.", arguments: inputs)
    func templateMatchesLegacyWrapper(_ input: Inputs) throws {
        let rendered = try AgentHookInstaller.codexWrapperScript(
            wrapperDirectory: input.wrapperDirectory,
            grafttyCLIPath: input.grafttyCLIPath,
            codexHomeDirectory: input.codexHomeDirectory,
            codexSourceDirectory: input.codexSourceDirectory,
            codexLockCommandPath: input.codexLockCommandPath
        )
        let legacy = LegacyCodexWrapperScript.render(
            wrapperDirectory: input.wrapperDirectory,
            grafttyCLIPath: input.grafttyCLIPath,
            codexHomeDirectory: input.codexHomeDirectory,
            codexSourceDirectory: input.codexSourceDirectory,
            codexLockCommandPath: input.codexLockCommandPath
        )
        #expect(Data(rendered.utf8) == Data(legacy.utf8))
    }

    @Test("@spec AGENT-6.58: When Graftty renders the Codex launch wrapper from its bundled shell template, the application shall substitute every placeholder in one pass, never expand placeholder text inside a substituted value, and fail when the template and the supplied values disagree.")
    func placeholdersAreSubstitutedInOnePass() throws {
        #expect(
            try AgentHookInstaller.renderShellTemplate(
                "a={{A}} b={{B}}",
                values: ["A": "{{B}}", "B": "{{A}}"]
            ) == "a={{B}} b={{A}}"
        )
        #expect(throws: AgentHookInstaller.ShellTemplateError.unknownPlaceholder("C")) {
            try AgentHookInstaller.renderShellTemplate("{{A}} {{C}}", values: ["A": "x"])
        }
        #expect(throws: AgentHookInstaller.ShellTemplateError.unusedValues(["B"])) {
            try AgentHookInstaller.renderShellTemplate("{{A}}", values: ["A": "x", "B": "y"])
        }
        #expect(throws: AgentHookInstaller.ShellTemplateError.unterminatedPlaceholder("A")) {
            try AgentHookInstaller.renderShellTemplate("x {{A\ny", values: [:])
        }
    }
}
