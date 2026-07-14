import Foundation
import GrafttyProtocol
import Testing
@testable import GrafttyKit

@Suite("WebServer - /ghostty-keybindings endpoint", .serialized)
struct GhosttyKeybindingsEndpointTests {
    private static func startServer(
        config: WebServer.Config,
        isAllowed: @escaping @Sendable (String) async -> Bool = { _ in true }
    ) throws -> (server: WebServer, port: Int) {
        let server = WebServer(
            config: config,
            auth: WebServer.AuthPolicy(isAllowed: isAllowed),
            bindAddresses: ["127.0.0.1"],
            tlsProvider: try makeTestTLSProvider()
        )
        try server.start()
        guard case let .listening(_, port) = server.status else {
            throw NSError(domain: "test", code: 1)
        }
        return (server, port)
    }

    @Test("""
    @spec WEB-9.9: When Web Access receives GET /ghostty-keybindings, the server shall return a JSON object whose bindings map Ghostty action raw names to the host-resolved ShortcutChord values so remote clients can install the same app-level command shortcuts as the host.
    """)
    func ghosttyKeybindingsEndpointEncodesResolvedChords() async throws {
        if skipInCI() { return }

        let expected: [GhosttyAction: ShortcutChord] = [
            .newSplitRight: ShortcutChord(key: "d", modifiers: .command),
            .nextTab: ShortcutChord(key: "tab", modifiers: .control),
        ]
        let config = WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp"),
            ghosttyKeybindingsProvider: { expected }
        )
        let (server, port) = try Self.startServer(config: config)
        defer { server.stop() }

        let (data, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/ghostty-keybindings")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bindings = try #require(json["bindings"] as? [String: Any])
        let splitRight = try #require(bindings[GhosttyAction.newSplitRight.rawValue] as? [String: Any])
        let nextTab = try #require(bindings[GhosttyAction.nextTab.rawValue] as? [String: Any])
        #expect(splitRight["key"] as? String == "d")
        #expect(splitRight["modifiers"] as? Int == ShortcutModifiers.command.rawValue)
        #expect(nextTab["key"] as? String == "tab")
        #expect(nextTab["modifiers"] as? Int == ShortcutModifiers.control.rawValue)

        let decoded = try JSONDecoder().decode(GhosttyKeybindingsResponse.self, from: data)
        #expect(decoded.bindings[GhosttyAction.newSplitRight.rawValue] == expected[.newSplitRight])
        #expect(decoded.bindings[GhosttyAction.nextTab.rawValue] == expected[.nextTab])
    }

    @Test("""
    @spec WEB-9.10: While no ghostty-keybindings provider is wired (e.g. the host app is still starting up), GET /ghostty-keybindings shall return 503 rather than an empty 200 map, so remote clients fall back to their bundled defaults instead of caching an empty binding set as host-resolved.
    """)
    func ghosttyKeybindingsEndpointReturns503BeforeProviderWired() async throws {
        if skipInCI() { return }

        let config = WebServer.Config(
            port: 0,
            zmxExecutable: URL(fileURLWithPath: "/dev/null"),
            zmxDir: URL(fileURLWithPath: "/tmp")
        )
        let (server, port) = try Self.startServer(config: config)
        defer { server.stop() }

        let (_, response) = try await trustAllData(
            from: URL(string: "https://localhost:\(port)/ghostty-keybindings")!
        )
        let http = response as! HTTPURLResponse
        #expect(http.statusCode == 503)
    }
}
