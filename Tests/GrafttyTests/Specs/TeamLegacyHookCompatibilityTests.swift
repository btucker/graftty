import Foundation
import Testing
@testable import GrafttyCLI

@Suite("Legacy team hook command compatibility")
struct TeamLegacyHookCompatibilityTests {
    @Test("""
    @spec AGENT-6.47: When a Claude session launched by an older Graftty invokes the removed `graftty team watch-inbox <runtime>` Stop hook, the CLI shall accept its arguments, drain the hook payload from standard input, and exit successfully without output or inbox work, and shall hide the command from help.
    """)
    func watchInboxIsAHiddenNoOp() throws {
        _ = try TeamWatchInbox.parse(["claude"])
        _ = try TeamWatchInbox.parse(["codex", "--unexpected", "value"])
        #expect(TeamWatchInbox.configuration.shouldDisplay == false)
        #expect(!Team.helpMessage().contains("watch-inbox"))

        let stdin = Pipe()
        let payload = Data(#"{"session_id":"abc","cwd":"/nowhere"}"#.utf8)
        stdin.fileHandleForWriting.write(payload)
        try stdin.fileHandleForWriting.close()
        TeamWatchInbox.drainHookPayload(stdin.fileHandleForReading)
        #expect(stdin.fileHandleForReading.availableData.isEmpty)
    }

    @Test("""
    @spec AGENT-6.48: When an older Graftty session invokes `graftty team hook` without `--skill-managed`, the CLI shall handle it exactly as a provider-plugin hook, and shall keep accepting the `--skill-managed` flag as a hidden no-op.
    """)
    func teamHookAcceptsLegacyAndPluginInvocations() throws {
        let legacy = try TeamHook.parse(["claude", "stop"])
        let plugin = try TeamHook.parse(["claude", "stop", "--skill-managed"])
        #expect(legacy.runtime == plugin.runtime)
        #expect(legacy.event == plugin.event)
        #expect(!TeamHook.helpMessage().contains("--skill-managed"))
    }
}
