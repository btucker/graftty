import Testing
@testable import Graftty

/// AGENT-6.60's spec test covers zmx-spawned shells; this covers the direct
/// (non-zmx) shell environment SurfaceHandle hands libghostty.
struct SurfaceHandleDirectShellEnvironmentTests {
    @Test(arguments: [nil, "/hooks/bin"] as [String?])
    func directShellRendersClaudeInline(agentHookBin: String?) {
        let pairs = SurfaceHandle.directShellEnvironment(
            socketPath: "/tmp/graftty.sock", sanitizedPath: "/usr/bin",
            agentHookBin: agentHookBin, zshInitDirectory: "/zsh-init")
        let env = Dictionary(pairs.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
        #expect(env["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] == "1")
        #expect(env["GRAFTTY_SOCK"] == "/tmp/graftty.sock")
        #expect(env["PATH"] == (agentHookBin.map { "\($0):/usr/bin" } ?? "/usr/bin"))
        #expect(env["ZDOTDIR"] == (agentHookBin == nil ? nil : "/zsh-init"))
    }
}
