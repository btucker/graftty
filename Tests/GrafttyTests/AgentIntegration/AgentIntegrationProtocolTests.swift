import Foundation
import Testing

@Suite("Scripted agent integration protocol")
struct AgentIntegrationProtocolTests {
    @Test("@spec TEST-1.12: When the native notification fixture validates its private queue, the harness shall compare canonical directory paths independently of URL directory metadata and reject other directories.")
    func privateAttentionDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let manifest = AgentIntegrationManifest(endpoint: URL(string: "http://127.0.0.1")!,
            root: root.path, cli: "", zmx: "", codex: "", claude: "", seed: 1)
        let path = root.appendingPathComponent("attention").path
        #expect(manifest.usesPrivateAttentionDirectory(URL(fileURLWithPath: path, isDirectory: true)))
        #expect(manifest.usesPrivateAttentionDirectory(URL(fileURLWithPath: path, isDirectory: false)))
        #expect(!manifest.usesPrivateAttentionDirectory(root.appendingPathComponent("attention-other")))
        #expect(!manifest.usesPrivateAttentionDirectory(root.appendingPathComponent("attention/child")))
        #expect(!manifest.usesPrivateAttentionDirectory(URL(string: "https://example.invalid" + path)!))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        #expect(manifest.usesPrivateAttentionDirectory(alias.appendingPathComponent("attention", isDirectory: true)))
    }

    @Test("@spec TEST-1.11: When the native notification integration replays a captured provider stop, the harness shall preserve its original payload and route explicit notification actions to native clients.")
    func notificationActionRoundTrip() throws {
        for operation in ["notificationsSnapshot", "notificationsReplay", "notificationsPrepare",
                          "notificationsDeliver", "notificationsState", "notificationsRelease",
                          "notificationsNavigate", "notificationsTap", "notificationsAuthorize", "notificationsDismissError", "notificationsCapture"] {
            let command = AgentIntegrationCommand(id: 21, operation: operation, provider: "codex",
                parameters: ["events": "[{\"runtime\":\"codex\",\"stoppedAt\":123.456}]", "copies": "3"])
            #expect(command.isSupported)
            #expect(try JSONDecoder().decode(AgentIntegrationCommand.self,
                from: JSONEncoder().encode(command)) == command)
        }
    }

    @Test("@spec TEST-1.8: When a scripted terminal is hidden and shown to reproduce worktree switching, the integration harness shall remount its retained surface or mobile route and observe its viewport and physical rows.")
    func visibilityActionRoundTrip() throws {
        let command = AgentIntegrationCommand(id: 13, operation: "visibility", provider: "codex",
            parameters: ["visible": "false"])
        #expect(command.isSupported)
        #expect(try JSONDecoder().decode(AgentIntegrationCommand.self,
            from: JSONEncoder().encode(command)) == command)
    }

    @Test("@spec TEST-1.1: When an integration client receives a resize, loaded-history read, or Quick Look action, the test harness shall preserve its sequence ID, provider, operation, and parameters through JSON encoding and admit it for dispatch.", arguments: ["resize", "loadedHistory", "previewPrepare", "previewSnapshot", "previewRemoved", "previewInput", "previewHideKeyboard", "previewOpen", "previewCapture", "previewDismiss", "previewBack"])
    func actionRoundTrip(operation: String) throws {
        let command = AgentIntegrationCommand(id: 12, operation: operation, provider: "codex",
            parameters: ["width": "393", "height": "852"])
        #expect(command.isSupported)
        #expect(try JSONDecoder().decode(AgentIntegrationCommand.self,
            from: JSONEncoder().encode(command)) == command)
    }

    @Test("@spec TEST-1.2: If a scripted integration action names an unsupported operation, then the test harness shall reject it rather than report a successful observation.")
    func rejectsUnknownActions() {
        #expect(!AgentIntegrationCommand(id: 1, operation: "silently-pass").isSupported)
        #expect(AgentIntegrationCommand(id: 2, operation: "snapshot").isSupported)
    }

    @Test("@spec TEST-1.6: When a native integration viewport contains wrapped fixture output, the test harness shall identify its reading anchor by the first logical row label rather than by physical row count.")
    func logicalRowAnchor() {
        #expect(AgentIntegrationAnchor.first(in: "continued text\nROW-000123 short\nROW-000124 next") == "ROW-000123")
        #expect(AgentIntegrationAnchor.first(in: "no numbered content").isEmpty)
    }

    @Test("@spec TEST-1.7: When a native follower displays history and a clipped terminal canvas, the integration harness shall derive its text and reading anchor from intersecting physical rows in display order.")
    func clippedFollowerRows() {
        let viewport = CGRect(x: 0, y: 15, width: 100, height: 20)
        let history = AgentIntegrationViewport.visibleRows("ROW-000001\nROW-000002", frame: CGRect(x: 0, y: 0, width: 100, height: 20), viewport: viewport, rowHeight: 10)
        let canvas = AgentIntegrationViewport.visibleRows("ROW-000003\nROW-000004\nROW-000005", frame: CGRect(x: 0, y: 20, width: 100, height: 30), viewport: viewport, rowHeight: 10)
        #expect(history == "ROW-000002")
        #expect(canvas == "ROW-000003\nROW-000004")
        #expect(AgentIntegrationAnchor.first(in: history + "\n" + canvas) == "ROW-000002")
        #expect(AgentIntegrationViewport.visibleRows("hidden", frame: CGRect(x: 0, y: 40, width: 100, height: 10), viewport: viewport, rowHeight: 10).isEmpty)
    }

    @Test("@spec TEST-1.3: When an integration action completes, the test harness shall correlate its renderer and ownership observation with the originating sequence ID.")
    func observationRoundTrip() throws {
        let observation = AgentIntegrationObservation(id: 9, client: "mobile", provider: "claude",
            values: ["text": "漢字 e\u{301}", "owner": "phone", "revision": "7"], error: nil)
        #expect(try JSONDecoder().decode(AgentIntegrationObservation.self,
            from: JSONEncoder().encode(observation)) == observation)
    }
}
