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
@Suite("Native scripted agent integration", .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["GRAFTTY_AGENT_INTEGRATION_MANIFEST"] != nil))
struct AgentIntegrationNativeTests {
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
    var finishedSuccessfully = false
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
        runtime = try HeadlessHostRuntime(configuration: configuration, terminals: driver)
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
        runtime.startMaintenance()
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
        try await transport.register(["fingerprint": String(decoding: JSONEncoder().encode(fingerprint), as: UTF8.self),
            "clientKey": phoneKey.rawRepresentation.base64EncodedString()])
        try await transport.run { [self] in try await handle($0) }
        #expect(finishedSuccessfully, "The integration controller must finish with a passing result")
    }

    func handle(_ command: AgentIntegrationCommand) async throws -> [String: String] {
        if command.operation == "finish" {
            finishedSuccessfully = command.parameters["result"] == "passed"
            return [:]
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
            let exactCommand = provider == .claude
                ? "claude --permission-mode manual -- " + WorktreeAgentLaunchCommand.shellLiteral(prompt)
                : command.parameters["history"] == "true"
                    ? "codex --no-alt-screen -- " + WorktreeAgentLaunchCommand.shellLiteral(prompt) : nil
            let launch = try WorktreeAgentLaunchCommand.prepare(agent: provider, prompt: prompt, exactCommand: exactCommand,
                promptDirectory: root.appendingPathComponent("prompts"))
            // Per-agent model URL is inherited by both Codex processes. The
            // generated wrapper and provider plugins remain installed and active.
            let base = manifest.endpoint.appendingPathComponent("model/\(command.provider)").absoluteString
            let environment = provider == .claude ? "ANTHROPIC_BASE_URL=\(WorktreeAgentLaunchCommand.shellLiteral(base))"
                : "OPENAI_BASE_URL=\(WorktreeAgentLaunchCommand.shellLiteral(base + "/v1"))"
            // Fullscreen provider virtualization has no terminal scrollback. The
            // history scenario selects Codex inline and Claude classic modes.
            let historyEnvironment = command.parameters["history"] == "true" && provider == .claude
                ? "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 " : ""
            let initial = "export \(historyEnvironment)GRAFTTY_TEST_AGENT=\(WorktreeAgentLaunchCommand.shellLiteral(command.provider)) \(environment)\n" + (launch.command ?? "")
            let created = try await runtime.createWorktree(repository: repo, name: command.provider,
                branch: command.provider, command: initial)
            let native = try #require(driver.panes[created.session])
            panes[command.provider] = Pane(path: created.path, session: created.session,
                handle: native.handle, window: native.window)
            let keys = ["NO_COLOR", "TERM", "COLORTERM", "TERM_PROGRAM", "FORCE_COLOR"]
            let hostEnv = ProcessInfo.processInfo.environment.filter { keys.contains($0.key) }
            let terminalEnv = driver.configurations[created.session]?.env.filter { keys.contains($0.key) } ?? [:]
            return ["session": created.session, "path": created.path,
                "hostColorEnvironment": String(decoding: try JSONEncoder().encode(hostEnv), as: UTF8.self),
                "terminalColorEnvironment": String(decoding: try JSONEncoder().encode(terminalEnv), as: UTF8.self)]
        }
        if command.operation == "roster" {
            let records = try TeamPresenceStorage(rootDirectory: runtime.configuration.stateDirectory.appendingPathComponent("teams")).listAll()
            let directory = TeamAgentDirectory(records: records, isReachable: TeamAgentReachability.isReachable)
            let agents = directory.agents.map { ["id": $0.id.rawValue, "path": $0.worktreePath,
                "runtime": $0.runtime.rawValue, "reachable": String($0.isReachable)] }
            return ["agents": String(decoding: try JSONEncoder().encode(agents), as: UTF8.self)]
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
            pane.handle.pressReturn()
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
        var values = ["text": text, "nativeText": nativeText, "buffer": bufferText, "anchor": AgentIntegrationAnchor.first(in: text),
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
    func close() async {
        await agent?.close(); agent = nil
        if let tickObserver { NotificationCenter.default.removeObserver(tickObserver) }
        for pane in panes.values { pane.window.orderOut(nil); pane.window.contentView = nil }
        panes.removeAll()
        let sessions = runtime.sessions()
        for session in sessions { try? await runtime.closePane(target: session.name) }
        try? runtime.shutdown()
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
        window.contentView = NSHostingView(rootView: SurfaceViewWrapper(handle: handle,
            theme: app.theme, onFocusTerminal: {}))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        handle.setVisible(true)
        guard handle.startForBackgroundLaunch() else { throw AgentIntegrationError("Mac surface failed to start") }
        handle.resyncVisibleGrid()
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
