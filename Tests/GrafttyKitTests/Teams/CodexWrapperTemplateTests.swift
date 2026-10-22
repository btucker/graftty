import Foundation
import Testing
@testable import GrafttyKit

@Suite("Codex wrapper shell template")
struct CodexWrapperTemplateTests {
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

    @Test("The template renders the same bytes as the Swift-literal wrapper it replaced.", arguments: inputs)
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
    }
}
