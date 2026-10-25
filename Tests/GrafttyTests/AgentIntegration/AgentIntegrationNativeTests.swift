import AppKit
import SwiftUI
import CryptoKit
import CoreImage
import Foundation
import GhosttyKit
import IOSurface
import GrafttyHostAgent
import GrafttyProtocol
import Testing
import WebRTC
@testable import Graftty
@testable import GrafttyKit

@MainActor
@Suite("@spec TEST-1.10: When the native integration harness creates a worktree through the production background creation flow, the harness shall require backend and initial-command readiness without mounting a terminal view or changing the selected worktree, and preserve startup diagnostics on failure.", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_AGENT_INTEGRATION_MANIFEST"] != nil))
struct AgentIntegrationNativeTests {
    @Test("Roster JSON distinguishes native provider bindings from wrapper registration")
    func rosterPreservesNativeIdentity() throws {
        let records = [
            TeamPresenceRecord(teamID: "fixture", worktree: "/fixture/claude", runtime: .claude,
                paneSessionName: "graftty-claude", pid: 1, registeredAt: Date(timeIntervalSince1970: 1),
                runtimeSessionID: "claude-native-session", agentID: "claude-111111111111",
                transport: .claude(socketPath: "/fixture/claude.sock", protocolVersion: 1)),
            TeamPresenceRecord(teamID: "fixture", worktree: "/fixture/codex", runtime: .codex,
                paneSessionName: "graftty-codex", pid: 2, registeredAt: Date(timeIntervalSince1970: 2),
                runtimeSessionID: "codex-native-thread", agentID: "codex-222222222222",
                transport: .codex(binaryPath: "/fixture/codex", socketPath: "/fixture/codex.sock",
                    threadID: "codex-native-thread", activeTurnID: nil)),
            TeamPresenceRecord(teamID: "fixture", worktree: "/fixture/wrapper", runtime: .codex,
                paneSessionName: "graftty-wrapper", pid: 3, registeredAt: Date(timeIntervalSince1970: 3),
                agentID: "codex-333333333333"),
        ]
        let json = try AgentIntegrationRoster.encode(records: records, isReachable: { _ in true })
        let rows = try JSONDecoder().decode([[String: String]].self, from: Data(json.utf8))
        #expect(rows.count == records.count)
        for record in records {
            let row = try #require(rows.first { $0["path"] == record.worktree })
            #expect(row["id"] == record.agentID)
            #expect(row["runtime"] == record.runtime.rawValue)
            #expect(row["reachable"] == "true")
            #expect(row["paneSessionName"] == record.paneSessionName)
            #expect(row["runtimeSessionID"] == (record.runtimeSessionID ?? ""))
        }
        let claude = try #require(rows.first { $0["runtime"] == "claude" })
        #expect(claude["transport"] == "claude")
        #expect(claude["transportThreadID"] == "")
        let codex = try #require(rows.first { $0["path"] == "/fixture/codex" })
        #expect(codex["transport"] == "codex")
        #expect(codex["transportThreadID"] == "codex-native-thread")
        let wrapper = try #require(rows.first { $0["path"] == "/fixture/wrapper" })
        #expect(wrapper["runtimeSessionID"] == "")
        #expect(wrapper["transport"] == "")
        #expect(wrapper["transportThreadID"] == "")
    }

    @Test("@spec TEST-1.4: When real scripted agents move between native Mac and mobile displays, the integration harness shall exercise production terminal ownership and messaging paths and fail if a commanded native action fails.", .timeLimit(.minutes(15)))
    func nativeClients() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GRAFTTY_AGENT_INTEGRATION_MANIFEST"])
        let manifest = try JSONDecoder().decode(AgentIntegrationManifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let host = try await AgentIntegrationMacHost(manifest: manifest)
        do {
            try await host.run()
        } catch {
            await host.close()
            throw error
        }
        await host.close()
    }
}

private enum AgentIntegrationRoster {
    static func encode(
        records: [TeamPresenceRecord],
        isReachable: (TeamPresenceRecord) -> Bool = TeamAgentReachability.isReachable
    ) throws -> String {
        let directory = TeamAgentDirectory(records: records, isReachable: isReachable)
        let agents = directory.agents.map { agent -> [String: String] in
            let record = records.first {
                TeamAgentDirectory.identity(for: $0) == agent.id
                    && $0.teamID == agent.teamID && $0.worktree == agent.worktreePath
                    && $0.paneSessionName == agent.paneSessionName
                    && $0.registeredAt == agent.registeredAt && $0.transport == agent.transport
            }
            var row = ["id": agent.id.rawValue, "path": agent.worktreePath,
                "runtime": agent.runtime.rawValue, "reachable": String(agent.isReachable),
                "runtimeSessionID": record?.runtimeSessionID ?? "",
                "paneSessionName": agent.paneSessionName ?? "",
                "transport": "", "transportThreadID": ""]
            switch agent.transport {
            case .claude:
                row["transport"] = "claude"
            case .codex(_, _, let threadID, _):
                row["transport"] = "codex"
                row["transportThreadID"] = threadID
            case nil:
                break
            }
            return row
        }
        return String(decoding: try JSONEncoder().encode(agents), as: UTF8.self)
    }
}

@MainActor
private final class AgentIntegrationMacHost {
    struct Pane {
        let path: String
        let session: String
        let handle: SurfaceHandle
        let window: NSWindow
    }
    let manifest: AgentIntegrationManifest
    let root: URL
    let runtime: HeadlessHostRuntime
    let driver: AgentIntegrationMacDriver
    let ownership = SessionDisplayOwnershipStore()
    let attachments = RemoteAttachmentRegistry()
    let socket: SocketServer
    let app: GhosttyApp
    let hostKey = Curve25519.Signing.PrivateKey()
    let phoneKey = Curve25519.Signing.PrivateKey()
    let peers: TrustedPeerStore
    var agent: WebRTCHostAgent?
    var panes: [String: Pane] = [:]
    var tickObserver: NSObjectProtocol?
    var previewOwnershipObserver: SessionDisplayOwnershipStore.ObserverToken?
    var notificationProbe: AgentIntegrationNotificationProbe?
    var finishedSuccessfully = false
    var productionCreation: ProductionWorktreeCreationFixture?
    var repo: String { root.appendingPathComponent("repository").path }

    init(manifest: AgentIntegrationManifest) async throws {
        self.manifest = manifest
        root = URL(fileURLWithPath: manifest.root)
        // Fail closed before installers or provider processes can touch user state.
        let expectedHome = root.appendingPathComponent("home").resolvingSymlinksInPath().standardizedFileURL.path
        let actualHome = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        let actualState = AppState.defaultDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        guard actualHome == expectedHome, actualState.hasPrefix(expectedHome + "/") else {
            throw AgentIntegrationError("native host isolation mismatch: home=\(actualHome), expected=\(expectedHome), state=\(actualState)")
        }
        if manifest.scenario == "notifications" || manifest.scenario == "preview" {
            guard manifest.usesPrivateAttentionDirectory(AttentionFileHandoff.defaultRootDirectory) else {
                throw AgentIntegrationError("integration fixture must use its private attention directory")
            }
        }
        let configuration = HostConfiguration(stateDirectory: AppState.defaultDirectory,
            runtimeDirectory: root.appendingPathComponent("run"), zmxExecutable: URL(fileURLWithPath: manifest.zmx), shell: "/bin/zsh")
        try configuration.prepareDirectories()
        _ = try AgentHookInstaller(rootDirectory: configuration.hooksDirectory, grafttyCLIPath: manifest.cli).install()
        let installer = AgentPluginInstaller(grafttyCLIPath: manifest.cli)
        let report = await installer.install(try installer.prepare(destinationRoot: configuration.stateDirectory.appendingPathComponent("agent-plugins")), executor: CLIRunner())
        guard report.succeeded else { throw AgentIntegrationError(report.summary) }
        _ = NSApplication.shared
        guard ghostty_init(0, nil) == 0 else { throw AgentIntegrationError("Ghostty initialization failed") }
        app = GhosttyApp(config: GhosttyConfig()) { _, _ in true }
        driver = AgentIntegrationMacDriver(app: app, configuration: configuration,
            ownership: ownership, attachments: attachments)
        runtime = try HeadlessHostRuntime(configuration: configuration, terminals: driver,
            agentSetup: HostAgentSetup(configuration: configuration, installer: installer))
        tickObserver = GhosttyWakeupBridge.observe { [app, driver] in
            app.tick()
            driver.updateScrollbars()
        }
        peers = TrustedPeerStore(directory: root.appendingPathComponent("peers"))
        try peers.upsertAfterPairing(TrustedPeer(id: RemoteDeviceID(value: "integration-phone"), kind: .iphone,
            publicKey: RemoteIdentityPublicKey(rawRepresentation: phoneKey.publicKey.rawRepresentation),
            displayName: "Integration phone", capabilities: .defaultsAfterPairing, pairedAt: Date(), lastSeenAt: nil))
        socket = SocketServer(socketPath: configuration.socketPath)
        socket.onAsyncRequest = { [runtime] in await runtime.handle($0) }
        socket.onMessage = { [runtime] message in
            if !message.expectsResponse { Task { _ = await runtime.handle(message) } }
        }
        try socket.start()
        runtime.startTeamDelivery()
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-b", "main"], ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty", "-m", "fixture"]] {
            let result = try await CLIRunner().run(command: "/usr/bin/git", args: arguments, at: repo)
            guard result.exitCode == 0 else { throw AgentIntegrationError(result.stderr) }
        }
        _ = try await runtime.registerRepository(repo)
        if manifest.scenario == "notifications" {
            notificationProbe = try AgentIntegrationNotificationProbe(runtime: runtime, root: root)
        } else {
            runtime.startMaintenance()
        }
        if manifest.scenario == "preview" {
            // This driver bypasses TerminalManager, so mirror its ownership
            // observer: the existing zmx leader must adopt the new owner's
            // grid even before that owner sends its first input.
            previewOwnershipObserver = ownership.addObserver { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self, self.previewOwnershipObserver != nil else { return }
                    self.driver.panes[snapshot.sessionName]?.handle.synchronizeDisplayOwnership()
                }
            }
        }
    }

    func makeAgent() -> WebRTCHostAgent {
        let runtime = runtime
        let launcher = runtime.launcher
        let attachments = attachments
        return WebRTCHostAgent(hostKey: hostKey, trustedPeerStore: peers,
            streamFactory: { target in
                let config = try await runtime.sessionConfiguration(target)
                let engine = ZmxAttachEngine(config: .init(zmxExecutable: launcher.executable, zmxDir: launcher.zmxDir,
                    sessionName: target, workingDirectory: config.workingDirectory, spawnConfiguration: config))
                engine.attachmentRegistry = attachments
                try await Task.detached { try engine.start() }.value
                return engine
            }, pagedFactory: { target in
                let config = try await runtime.sessionConfiguration(target)
                let engine = PagedZmxAttachEngine(config: .init(zmxExecutable: launcher.executable, zmxDir: launcher.zmxDir,
                    sessionName: target, workingDirectory: config.workingDirectory, spawnConfiguration: config))
                engine.attachmentRegistry = attachments
                try await engine.start()
                return engine
            }, panesStateSubscribe: { onChange in
                await onChange(await runtime.panesMessage())
                return .init(cancel: {})
            }, paneControlMutator: { await runtime.control($0) },
            worktreeManagementMutator: { await runtime.manage($0) }, displayOwnershipStore: ownership)
    }

    func run() async throws {
        let transport = AgentIntegrationTransport(endpoint: manifest.endpoint, client: "mac")
        let fingerprint = RemoteIdentityFingerprint(of: try RemoteIdentityPublicKey(rawRepresentation: hostKey.publicKey.rawRepresentation))
        let executable = try #require(Bundle(for: AgentIntegrationMacHost.self).executableURL)
        let executableHash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
        try await transport.register(["fingerprint": String(decoding: JSONEncoder().encode(fingerprint), as: UTF8.self),
            "nativeExecutable": executable.path, "nativeExecutableSHA256": executableHash,
            "clientKey": phoneKey.rawRepresentation.base64EncodedString()])
        try await transport.run { [self] in try await handle($0) }
        #expect(finishedSuccessfully, "The integration controller must finish with a passing result")
    }

    func handle(_ command: AgentIntegrationCommand) async throws -> [String: String] {
        if command.operation == "finish" {
            finishedSuccessfully = command.parameters["result"] == "passed"
            return [:]
        }
        if command.operation == "notificationsSnapshot" || command.operation == "notificationsReplay" {
            let probe = try #require(notificationProbe)
            let pane = try #require(panes[command.provider])
            return try await probe.handle(command, path: pane.path)
        }
        if command.operation == "acceptOffer" {
            await agent?.close()
            let next = makeAgent()
            agent = next
            let answer = try await next.acceptOffer(RTCSessionDescription(type: .offer,
                sdp: try required(command, "sdp")), clientDeviceID: RemoteDeviceID(value: "integration-phone"))
            return ["sdp": answer.sdp]
        }
        if command.operation == "start" {
            let provider = command.provider.hasPrefix("claude") ? TeamHookRuntime.claude : .codex
            let prompt = "GRAFTTY_TEST_BEGIN \(command.provider)"
            let background = command.parameters["background"] == "true"
            driver.mountNewPanes = !background
            defer { driver.mountNewPanes = true }
            let created: (path: String, session: String)
            if background, command.parameters["backgroundFlow"] == "app-flow" {
                if productionCreation == nil {
                    productionCreation = ProductionWorktreeCreationFixture(runtime: runtime,
                        ownership: ownership, attachments: attachments, root: root)
                }
                let launched = try await productionCreation!.create(repository: repo, name: command.provider,
                    initialCommand: initialCommand(provider: provider, name: command.provider))
                created = (launched.path, launched.session)
                // A window is retained only for later explicit visibility actions.
                // No view is attached during provider launch or mobile ownership.
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: true)
                panes[command.provider] = Pane(path: created.path, session: created.session,
                    handle: launched.handle, window: window)
            } else if background {
                // The CLI uses the isolated control socket. No selection, layout,
                // or visible native window is allowed to kick off this launch.
                let result = try await CLIRunner().capture(command: "/usr/bin/env", args: [
                    "GRAFTTY_SOCK=" + runtime.configuration.socketPath, manifest.cli,
                    "worktree", "add", command.provider, "--base", "HEAD", "--agent", provider.rawValue,
                    "--prompt", prompt, "--wait", "--timeout", "90"
                ], at: repo, timeout: .seconds(100))
                try ("exit=\(result.exitCode)\n" + result.stdout + "\nstderr:\n" + result.stderr)
                    .write(to: root.appendingPathComponent(command.provider + "-creation-cli.txt"),
                        atomically: true, encoding: .utf8)
                guard result.exitCode == 0 else {
                    throw AgentIntegrationError("Background CLI creation failed: " + result.stderr)
                }
                let path = repo + "/.worktrees/" + command.provider
                let session = try #require(runtime.sessions().first { $0.worktreePath == path })
                created = (path, session.name)
            } else {
                let initial = try initialCommand(provider: provider, name: command.provider,
                    history: command.parameters["history"] == "true")
                created = try await runtime.createWorktree(repository: repo, name: command.provider,
                    branch: command.provider, command: initial)
            }
            if panes[command.provider] == nil {
                let native = try #require(driver.panes[created.session])
                panes[command.provider] = Pane(path: created.path, session: created.session,
                    handle: native.handle, window: native.window)
            }
            let native = try #require(panes[command.provider])
            let keys = ["NO_COLOR", "TERM", "COLORTERM", "TERM_PROGRAM", "FORCE_COLOR"]
            let hostEnv = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
            let terminalEnv = driver.configurations[created.session]?.env.filter { keys.contains($0.key) } ?? [:]
            let hooksURL = runtime.configuration.stateDirectory.appendingPathComponent(
                "agent-plugins/\(provider.rawValue)/plugins/graftty/hooks/hooks.json")
            let launchEvidence = ["provider": command.provider, "cli": manifest.cli, "requestedPrompt": prompt,
                "claudeDisableAlternateScreen": ProcessInfo.processInfo.environment["CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN"] ?? "",
                "initialCommand": driver.configurations[created.session]?.env["GRAFTTY_INITIAL_COMMAND"] ?? "",
                "installedHooks": try String(contentsOf: hooksURL, encoding: .utf8)]
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(launchEvidence).write(to: root.appendingPathComponent(
                command.provider + "-creation-launch.txt"), options: .atomic)
            return ["session": created.session, "path": created.path,
                "viewMounted": String(native.handle.view.window != nil),
                "hostColorEnvironment": String(decoding: try JSONEncoder().encode(hostEnv), as: UTF8.self),
                "terminalColorEnvironment": String(decoding: try JSONEncoder().encode(terminalEnv), as: UTF8.self)]
        }
        if command.operation == "roster" {
            let records = try TeamPresenceStorage(rootDirectory: runtime.configuration.stateDirectory.appendingPathComponent("teams")).listAll()
            return ["agents": try AgentIntegrationRoster.encode(records: records)]
        }
        if command.operation == "recreate" {
            let old = try #require(panes[command.provider])
            panes[command.provider] = nil
            let previous = try #require(driver.configurations[old.session])
            var environment = previous.env
            environment["GRAFTTY_INITIAL_COMMAND"] = nil
            environment["GRAFTTY_STARTUP_RECEIPT"] = nil
            let spawn = ZmxSpawnConfiguration(sessionName: previous.sessionName, argv: previous.argv,
                env: environment, workingDirectory: previous.workingDirectory,
                shellReadySignalAvailable: previous.shellReadySignalAvailable)
            let grid = old.handle.queryGridSize()
            old.handle.disconnectAttachment()
            old.window.contentView = nil
            old.window.orderOut(nil)
            driver.panes[old.session] = nil
            try await driver.start(spawn, initialGrid: grid)
            let native = try #require(driver.panes[old.session])
            panes[command.provider] = Pane(path: old.path, session: old.session,
                handle: native.handle, window: native.window)
        }
        let pane = try #require(panes[command.provider])
        switch command.operation {
        case "visibility":
            let visible = try required(command, "visible") == "true"
            pane.handle.setVisible(visible)
            if visible {
                pane.window.contentView = NSHostingView(rootView: SurfaceViewWrapper(handle: pane.handle,
                    theme: app.theme, onFocusTerminal: {}))
                pane.window.contentView?.layoutSubtreeIfNeeded()
                pane.handle.resyncVisibleGrid()
                pane.handle.refresh()
            } else {
                pane.window.contentView = nil
            }
        case "resize":
            let width = try dimension(command, "width"), height = try dimension(command, "height")
            pane.window.setContentSize(NSSize(width: width, height: height))
            pane.window.contentView?.layoutSubtreeIfNeeded()
            pane.handle.resyncVisibleGrid()
        case "takeControl":
            guard pane.handle.takeDisplayControl() else { throw AgentIntegrationError("Mac takeover rejected") }
        case "scroll":
            var action = command.parameters["position"] == "bottom" ? "scroll_to_bottom" : "scroll_to_top"
            #if GRAFTTY_PAGED_HISTORY
            if command.parameters["position"] == "middle" {
                var bar = ghostty_action_scrollbar_s()
                ghostty_surface_read_scrollbar(pane.handle.surface, &bar)
                action = "scroll_to_row:\((bar.total - min(bar.total, bar.len)) / 2)"
            }
            #endif
            guard action.withCString({ ghostty_surface_binding_action(pane.handle.surface, $0, UInt(strlen($0))) }) else {
                throw AgentIntegrationError("Mac scroll action rejected")
            }
        case "select":
            guard "select_all".withCString({ ghostty_surface_binding_action(pane.handle.surface, $0, UInt(strlen($0))) }) else {
                throw AgentIntegrationError("Mac selection rejected")
            }
        case "input":
            if let text = command.parameters["text"], !text.isEmpty, !pane.handle.writeText(text) {
                throw AgentIntegrationError("Mac input rejected")
            }
            if command.parameters["submit"] != "false" { pane.handle.pressReturn() }
        case "message":
            let destination = try required(command, "destination")
            let text = try required(command, "text")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: manifest.cli)
            process.arguments = ["team", "send", "--stdin", destination] + (command.parameters["urgent"] == "true" ? ["--urgent"] : [])
            process.currentDirectoryURL = URL(fileURLWithPath: pane.path)
            var env = ProcessInfo.processInfo.environment
            env["GRAFTTY_SOCK"] = runtime.configuration.socketPath
            env["ZMX_SESSION"] = pane.session
            let records = try TeamPresenceStorage(rootDirectory: runtime.configuration.stateDirectory.appendingPathComponent("teams")).listAll()
            let directory = TeamAgentDirectory(records: records, isReachable: TeamAgentReachability.isReachable)
            guard let sender = directory.agents.first(where: { $0.worktreePath == pane.path && $0.isReachable }) else {
                throw AgentIntegrationError("sender has no reachable hook-bound agent identity")
            }
            env["GRAFTTY_AGENT_ID"] = sender.id.rawValue
            process.environment = env
            let input = Pipe(), output = Pipe()
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try input.fileHandleForWriting.close()
            let result = await Task.detached { () -> (Int32, Data) in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, data)
            }.value
            guard result.0 == 0 else { throw AgentIntegrationError(String(decoding: result.1, as: UTF8.self)) }
        case "snapshot", "verify", "recreate": break
        default: throw AgentIntegrationError("unsupported Mac action \(command.operation)")
        }
        try await Task.sleep(for: .milliseconds(30))
        app.tick()
        var result = try snapshot(pane)
        if command.operation == "verify" {
            result["authoritativeText"] = try await runtime.terminals.show(pane.session, lines: 10000)
        }
        if ["verify", "visibility", "recreate"].contains(command.operation),
           let contents = pane.handle.view.layer?.contents,
           CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            let imageSurface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
            result["imageSize"] = "\(IOSurfaceGetWidth(imageSurface))x\(IOSurfaceGetHeight(imageSurface))"
            let image = CIImage(ioSurface: imageSurface)
            if let cgImage = CIContext().createCGImage(image, from: image.extent) {
                let bitmap = NSBitmapImageRep(cgImage: cgImage)
                let filename = "\(command.provider)-\(command.id).png"
                try bitmap.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent(filename))
                result["image"] = filename
                if command.parameters["colors"] == "true" {
                    let pixels = AgentIntegrationColorProbe.counts(image: cgImage,
                        physicalRows: try physicalRows(pane.handle.surface),
                        cellHeight: Int(ghostty_surface_size(pane.handle.surface).cell_height_px),
                        markerSuffix: command.parameters["colorSuffix"] ?? "")
                    result["colorPixels"] = String(decoding: try JSONEncoder().encode(pixels), as: UTF8.self)
                }
            }
        }
        return result
    }

    func snapshot(_ pane: Pane) throws -> [String: String] {
        pane.handle.synchronizeDisplayOwnership()
        let size = ghostty_surface_size(pane.handle.surface)
        let state = ownership.snapshot(sessionName: pane.session, fallbackGrid: try DisplayGrid(cols: size.columns, rows: size.rows))
        var selection = ghostty_selection_s()
        selection.top_left.tag = GHOSTTY_POINT_VIEWPORT
        selection.top_left.coord = GHOSTTY_POINT_COORD_TOP_LEFT
        selection.bottom_right.tag = GHOSTTY_POINT_VIEWPORT
        selection.bottom_right.coord = GHOSTTY_POINT_COORD_BOTTOM_RIGHT
        var result = ghostty_text_s()
        let hasText = ghostty_surface_read_text(pane.handle.surface, selection, &result)
        let nativeText = hasText && result.text != nil ? String(cString: result.text) : ""
        if hasText { ghostty_surface_free_text(pane.handle.surface, &result) }
        var text = nativeText
        if let follower = pane.handle.followerPresentation, follower.followerGrid != nil {
            let viewport = follower.scrollView.contentView.bounds
            let scale = follower.scaledView.frame.height / max(1, follower.scaledView.bounds.height)
            let rowHeight = CGFloat(size.cell_height_px) / (pane.window.backingScaleFactor) * scale
            var visible: [String] = []
            if let history = follower.historySurfaceForTesting, let frame = follower.historyFrameForTesting {
                visible.append(AgentIntegrationViewport.visibleRows(try physicalRows(history),
                    frame: frame, viewport: viewport, rowHeight: rowHeight))
            }
            visible.append(AgentIntegrationViewport.visibleRows(try physicalRows(pane.handle.surface),
                frame: follower.scaledView.frame, viewport: viewport, rowHeight: rowHeight))
            text = visible.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        selection.top_left.tag = GHOSTTY_POINT_SCREEN
        selection.bottom_right.tag = GHOSTTY_POINT_SCREEN
        var buffer = ghostty_text_s()
        let hasBuffer = ghostty_surface_read_text(pane.handle.surface, selection, &buffer)
        let bufferText = hasBuffer && buffer.text != nil ? String(cString: buffer.text) : ""
        if hasBuffer { ghostty_surface_free_text(pane.handle.surface, &buffer) }
        var bar = ghostty_action_scrollbar_s()
        #if GRAFTTY_PAGED_HISTORY
        ghostty_surface_read_scrollbar(pane.handle.surface, &bar)
        #else
        bar = pane.handle.followerScrollbar
        #endif
        var selected = ghostty_text_s()
        let hasSelection = ghostty_surface_read_selection(pane.handle.surface, &selected)
        let selectedText = hasSelection && selected.text != nil ? String(cString: selected.text) : ""
        if hasSelection { ghostty_surface_free_text(pane.handle.surface, &selected) }
        let terminal = pane.handle.view
        var values = ["text": text, "viewMounted": String(pane.handle.view.window != nil), "nativeText": nativeText, "buffer": bufferText, "anchor": AgentIntegrationAnchor.first(in: text),
            "physicalRows": try physicalRows(pane.handle.surface),
            "surfaceFrame": NSStringFromRect(terminal.frame), "surfaceBounds": NSStringFromRect(terminal.bounds),
            "visibleRect": NSStringFromRect(terminal.visibleRect),
            "layerFrame": terminal.layer.map { NSStringFromRect($0.frame) } ?? "",
            "selected": selectedText, "revision": String(state.revision), "epoch": String(state.epoch),
            "owner": state.ownerClientID?.rawValue ?? "", "grid": "\(state.grid.cols)x\(state.grid.rows)",
            "ownerIdentity": state.ownerIdentity ?? "",
            "nativeGrid": "\(size.columns)x\(size.rows)", "offset": String(bar.offset), "total": String(bar.total),
            "len": String(bar.len), "session": pane.session]
        #if GRAFTTY_PAGED_HISTORY
        values["parserGridMatches"] = String(ghostty_surface_grid_matches(pane.handle.surface, size.columns, size.rows))
        if let rows = UInt16(exactly: bar.len), rows > 0 {
            values["parserGridAtScrollbarHeight"] = String(ghostty_surface_grid_matches(pane.handle.surface, size.columns, rows))
        }
        #endif
        return values
    }

    func physicalRows(_ surface: ghostty_surface_t) throws -> String {
        let size = ghostty_surface_size(surface)
        guard size.columns > 0 else { return "" }
        var lines: [String] = []
        for row in 0..<UInt32(size.rows) {
            let selection = ghostty_selection_s(
                top_left: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: row),
                bottom_right: .init(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                    x: UInt32(size.columns) - 1, y: row), rectangle: false)
            var text = ghostty_text_s()
            guard ghostty_surface_read_text(surface, selection, &text) else {
                throw AgentIntegrationError("native physical-row read failed")
            }
            let line = text.text.map { String(cString: $0) } ?? ""
            ghostty_surface_free_text(surface, &text)
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    func required(_ command: AgentIntegrationCommand, _ key: String) throws -> String {
        guard let value = command.parameters[key], !value.isEmpty else { throw AgentIntegrationError("missing \(key)") }
        return value
    }
    func dimension(_ command: AgentIntegrationCommand, _ key: String) throws -> Double {
        guard let value = Double(try required(command, key)), (100...2000).contains(value) else { throw AgentIntegrationError("invalid dimension") }
        return value
    }
    private func initialCommand(provider: TeamHookRuntime, name: String, history: Bool = false) throws -> String {
        let prompt = "GRAFTTY_TEST_BEGIN \(name)"
        let exactCommand = provider == .claude
            ? "claude --permission-mode manual -- " + WorktreeAgentLaunchCommand.shellLiteral(prompt)
            : history
                ? "codex --no-alt-screen -c tui.terminal_resize_reflow_max_rows=10000 -- "
                    + WorktreeAgentLaunchCommand.shellLiteral(prompt) : nil
        let launch = try WorktreeAgentLaunchCommand.prepare(agent: provider, prompt: prompt, exactCommand: exactCommand,
            promptDirectory: root.appendingPathComponent("prompts"))
        // Per-agent model URL is inherited by both Codex processes. The
        // generated wrapper and provider plugins remain installed and active.
        let base = manifest.endpoint.appendingPathComponent("model/\(name)").absoluteString
        let environment = provider == .claude ? "ANTHROPIC_BASE_URL=\(WorktreeAgentLaunchCommand.shellLiteral(base))"
            : "OPENAI_BASE_URL=\(WorktreeAgentLaunchCommand.shellLiteral(base + "/v1"))"
        let attention = manifest.scenario == "notifications" || manifest.scenario == "preview"
            ? " GRAFTTY_ATTENTION_DIR=\(WorktreeAgentLaunchCommand.shellLiteral(AttentionFileHandoff.defaultRootDirectory.path))" : ""
        // Fullscreen provider virtualization has no terminal scrollback. The
        // history scenario selects Codex inline and Claude classic modes.
        // Codex's default 1,000-row resize replay discards this dense fixture;
        // bound its source replay at 10,000 rows so all 600 wrapped rows survive.
        let historyEnvironment = history && provider == .claude
            ? "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 " : ""
        return "export \(historyEnvironment)GRAFTTY_TEST_AGENT=\(WorktreeAgentLaunchCommand.shellLiteral(name)) \(environment)\(attention)\n" + (launch.command ?? "")
    }

    func close() async {
        previewOwnershipObserver?.cancel()
        previewOwnershipObserver = nil
        await agent?.close(); agent = nil
        if let tickObserver { NotificationCenter.default.removeObserver(tickObserver) }
        for pane in panes.values { pane.window.orderOut(nil); pane.window.contentView = nil }
        panes.removeAll()
        productionCreation?.close()
        productionCreation = nil
        let sessions = runtime.sessions()
        for session in sessions { try? await runtime.closePane(target: session.name) }
        try? await runtime.shutdown()
        socket.stop()
    }
}

/// Mount the same native follower container as the desktop app before the
/// daemon starts. A second headless attach would otherwise own its initial grid.
@MainActor
private final class AgentIntegrationMacDriver: HostTerminalDriver {
    struct Pane {
        let handle: SurfaceHandle
        let window: NSWindow
    }
    let app: GhosttyApp
    let configuration: HostConfiguration
    let ownership: SessionDisplayOwnershipStore
    let attachments: RemoteAttachmentRegistry
    let commands: ZmxHostTerminalDriver
    var panes: [String: Pane] = [:]
    var configurations: [String: ZmxSpawnConfiguration] = [:]
    var mountNewPanes = true

    init(app: GhosttyApp, configuration: HostConfiguration,
         ownership: SessionDisplayOwnershipStore, attachments: RemoteAttachmentRegistry) {
        self.app = app; self.configuration = configuration
        self.ownership = ownership; self.attachments = attachments
        commands = ZmxHostTerminalDriver(launcher: ZmxLauncher(
            executable: configuration.zmxExecutable, zmxDir: configuration.zmxDirectory))
    }

    func start(_ spawn: ZmxSpawnConfiguration) async throws {
        try await start(spawn, initialGrid: nil)
    }

    func start(_ spawn: ZmxSpawnConfiguration, initialGrid: ghostty_surface_size_s?) async throws {
        configurations[spawn.sessionName] = spawn
        let handle = try #require(SurfaceHandle(terminalID: PaneSlotID(), app: app.app,
            worktreePath: spawn.workingDirectory.path, socketPath: configuration.socketPath,
            zmxSpawnConfiguration: spawn, remoteAttachmentRegistry: attachments,
            displayOwnershipStore: ownership,
            displayClientID: DisplayClientID("integration-mac-" + spawn.sessionName), initialGridSize: initialGrid))
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: 1000, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "Graftty integration: " + spawn.sessionName
        if mountNewPanes {
            window.contentView = NSHostingView(rootView: SurfaceViewWrapper(handle: handle,
                theme: app.theme, onFocusTerminal: {}))
            window.orderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            handle.setVisible(true)
        } else {
            window.contentView = nil
            handle.setVisible(false)
        }
        guard handle.startForBackgroundLaunch() else { throw AgentIntegrationError("Mac surface failed to start") }
        if !mountNewPanes {
            guard await handle.waitForBackendStartup() else { throw AgentIntegrationError("Mac shell startup was not acknowledged") }
        }
        if mountNewPanes { handle.resyncVisibleGrid() }
        panes[spawn.sessionName] = Pane(handle: handle, window: window)
        let deadline = Date().addingTimeInterval(5)
        while !(try await sessions()).contains(spawn.sessionName) {
            guard Date() < deadline else { throw AgentIntegrationError("Mac daemon did not start") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func updateScrollbars() {
        #if GRAFTTY_PAGED_HISTORY
        for pane in panes.values {
            var bar = ghostty_action_scrollbar_s()
            ghostty_surface_read_scrollbar(pane.handle.surface, &bar)
            pane.handle.updateFollowerScrollbar(bar)
        }
        #endif
    }
    func sessions() async throws -> Set<String> { try await commands.sessions() }
    func send(_ text: String, to session: String) async throws { try await commands.send(text, to: session) }
    func show(_ session: String, lines: Int) async throws -> String { try await commands.show(session, lines: lines) }
    func kill(_ session: String) async throws {
        if let pane = panes.removeValue(forKey: session) { pane.window.orderOut(nil); pane.window.contentView = nil }
        try await commands.kill(session)
    }
    func detachAll() {
        for pane in panes.values { pane.window.orderOut(nil); pane.window.contentView = nil }
        panes.removeAll()
    }
}
