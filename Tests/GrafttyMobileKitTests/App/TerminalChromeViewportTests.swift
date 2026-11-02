import CoreGraphics
import Foundation
import Testing
@testable import GrafttyMobileKit

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import GhosttyTerminal
import GrafttyCommandUI
import GrafttyProtocol
import GrafttyRemoteClient
import SwiftUI
import UIKit
#endif

#if canImport(UIKit) && !targetEnvironment(macCatalyst)
@Suite("@spec IOS-4.8: While a mobile terminal is displayed fullscreen, the application shall extend its scroll viewport to the top and bottom screen edges while protecting a lone first line below top chrome, keep floating controls within the safe area, and reserve only the keyboard and its control bar when the keyboard is visible.", .serialized)
@MainActor
struct RenderedTerminalViewportTests {
    @Test("Pending questions stay clear of a lone prompt and completed-agent actions.", arguments: [false, true])
    func pendingQuestionDoesNotCoverContent(completed: Bool) async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let question = "Should I keep the current implementation or try a different approach before opening the pull request?"
        let fixture = makeFixture(client: client, agentWorkspace: true, question: question, completed: completed)
        defer { fixture.window.isHidden = true }
        try await waitForLayout("pending question") {
            fixture.host.view.layoutIfNeeded()
            return accessibilityObjects(in: fixture.host.view).contains { $0.accessibilityLabel == question }
        }
        let request = try #require(accessibilityObjects(in: fixture.host.view).first { $0.accessibilityLabel == question })
        if completed {
            try await waitForLayout("completed agent resume action") {
                fixture.host.view.layoutIfNeeded()
                return accessibilityObjects(in: fixture.host.view).contains { $0.accessibilityLabel == "Resume session" }
            }
            let resume = try #require(accessibilityObjects(in: fixture.host.view).first { $0.accessibilityLabel == "Resume session" })
            #expect(resume.accessibilityFrame.minY >= request.accessibilityFrame.maxY + 8)
        } else {
            let container = try await renderedContainer(in: fixture.host.view)
            client.session.receive(Data("prompt".utf8))
            try await waitForLayout("first prompt") { client.session.readViewportText()?.contains("prompt") == true }
            let text = container.terminalView.convert(container.terminalView.bounds, to: fixture.window)
            #expect(text.minY >= request.accessibilityFrame.maxY + 8)
            #expect(abs(container.convert(container.bounds, to: fixture.window).minY) < 1)
            client.session.receive(Data("\r\nsecond line".utf8))
            try await waitForLayout("populated terminal still reaches top") {
                abs(container.terminalView.convert(container.terminalView.bounds, to: fixture.window).minY) < 1
            }
        }
    }

    @Test("Floating agent controls share one safe-area row at narrow widths and large text sizes.", arguments: [CGFloat(320), CGFloat(390), CGFloat(844)], [false, true])
    func compactHeaderFitsWithoutCoveringAdjacentControls(width: CGFloat, largeText: Bool) async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let fixture = makeFixture(client: client, agentWorkspace: true,
            size: CGSize(width: width, height: width > 600 ? 390 : 844), largeText: largeText)
        defer { fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        client.session.receive(Data((String(repeating: "Checking the floating iPhone header\r\n", count: 60) + "Ready > ").utf8))
        try await waitForLayout("multiline agent output") {
            container.layoutIfNeeded()
            return client.session.readViewportText()?.contains("Ready >") == true && container.snapshotScrollView.topContentInset == 0
        }
        try await waitForLayout("agent header accessibility") {
            fixture.host.view.layoutIfNeeded()
            let labels = accessibilityObjects(in: fixture.host.view).compactMap(\.accessibilityLabel)
            return labels.contains("Preview") && labels.contains(where: { $0.hasPrefix("Agents,") })
        }
        let objects = accessibilityObjects(in: fixture.host.view)
        let back = try #require(objects.first { $0.accessibilityLabel?.hasPrefix("Back to worktrees") == true })
        let switcher = try #require(objects.first { $0.accessibilityLabel?.hasPrefix("Agents,") == true })
        let preview = try #require(objects.first { $0.accessibilityLabel == "Preview" })
        for control in [back, switcher, preview] {
            #expect(control.accessibilityFrame.width >= 44 - 0.001)
            #expect(control.accessibilityFrame.height >= 44 - 0.001)
            #expect(control.accessibilityFrame.minY >= fixture.host.view.safeAreaInsets.top)
            #expect(abs(control.accessibilityFrame.midY - back.accessibilityFrame.midY) < 1)
            #expect(control.accessibilityFrame.minX >= 0 && control.accessibilityFrame.maxX <= width + 1)
        }
        #expect(back.accessibilityFrame.maxX <= switcher.accessibilityFrame.minX + 1)
        #expect(switcher.accessibilityFrame.maxX <= preview.accessibilityFrame.minX + 1)
        #expect(abs(container.convert(container.bounds, to: fixture.window).minY) < 1)
        #expect(container.acceptsTerminalInput(at: CGPoint(x: 100, y: 1)))

    }

    @Test("@spec IOS-4.57: While an iPhone agent terminal extends behind the status bar and Dynamic Island, the application shall blend its top edge into the shared worktree identity smear, fade that overlay into the terminal below, and preserve the terminal's touch handling.", arguments: [true, false])
    func terminalTopFadesIntoWorktreeSmear(dark: Bool) throws {
        let theme = dark ? GhosttyThemeColors.fallback : GhosttyThemeColors(
            backgroundRGB: .init(r: 0.98, g: 0.97, b: 0.94), foregroundRGB: .init(r: 0.1, g: 0.1, b: 0.1))
        let row = WorktreePanes(path: "/repo", displayName: "Phone header", repoDisplayName: "Repo", displayBranch: "phone-header",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil, layout: nil,
            sidebar: .init(id: "repo", projectID: "project", emoji: "🔥"))
        let renderer = ImageRenderer(content: Color(red: 0, green: 1, blue: 1)
            .overlay(alignment: .top) { MobileTerminalHeaderWash(worktree: row, theme: theme).frame(height: 160) }
            .frame(width: 390, height: 300))
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("terminal-wash-\(dark).png")
        try #require(UIImage(cgImage: image).pngData()).write(to: url)
        print("Wash render: \(url.path)")
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let top = (20 * image.width + 300) * 4
        #expect(Int(bytes[top]) > Int(bytes[top + 2]) + 10, "The top must carry the warm emoji smear, rather than a plain fade")
        let bottom = (220 * image.width + 50) * 4
        #expect(bytes[bottom] < 10 && bytes[bottom + 1] > 245 && bytes[bottom + 2] > 245,
                "The wash must leave terminal content below the header unchanged")
    }

    @Test("@spec IOS-4.56: While an iPhone agent terminal is visible, the application shall extend the terminal viewport to the screen's top and bottom edges behind a single floating row containing Back and the agent switcher on the left and the resource controls on the right, reserving only the keyboard and its control bar.", arguments: [CGFloat(0), CGFloat(300)])
    func compactAgentTerminalReachesScreenEdges(keyboardInset: CGFloat) async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let fixture = makeFixture(client: client, keyboardInset: keyboardInset, agentWorkspace: true)
        defer { fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        let frame = container.convert(container.bounds, to: fixture.window)
        let expectedBottom = fixture.window.bounds.maxY - keyboardInset - (keyboardInset > 0 ? 58 : 0)
        #expect(abs(frame.minY - fixture.window.bounds.minY) < 1, "Agent terminal leaves a top gap: \(frame)")
        #expect(abs(frame.maxY - expectedBottom) < 1, "Agent terminal ends at \(frame.maxY), expected \(expectedBottom)")

        client.session.receive(Data("prompt".utf8))
        try await waitForLayout("agent prompt clears floating controls") {
            let text = container.terminalView.convert(container.terminalView.bounds, to: fixture.window)
            return text.minY >= fixture.host.view.safeAreaInsets.top + 68
        }
        client.session.receive(Data("\r\nsecond line".utf8))
        try await waitForLayout("agent output reaches the physical top") {
            let text = container.terminalView.convert(container.terminalView.bounds, to: fixture.window)
            return abs(text.minY - fixture.window.bounds.minY) < 1
        }
    }

    @Test("@spec IOS-6.25: If an interactive mobile terminal has only its first line and no scrollback, then the application shall inset that line below top chrome on iPad and iPhone; otherwise, the application shall remove the clearance so terminal content can reach the pane's top and bottom edges.", arguments: [true, false], ["x", "界", "👩‍💻"])
    func chromeClearanceTracksFirstLineContent(embedded: Bool, wrappedCharacter: String) async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let fixture = makeFixture(client: client, embedded: embedded)
        defer { fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        func textFrame() -> CGRect {
            fixture.host.view.layoutIfNeeded()
            container.layoutIfNeeded()
            return container.terminalView.convert(container.terminalView.bounds, to: fixture.window)
        }
        let viewportTop = embedded ? fixture.host.view.safeAreaInsets.top : fixture.window.bounds.minY
        let minimumClearance = viewportTop + (embedded ? 0 : fixture.host.view.safeAreaInsets.top + 68)
        client.session.receive(Data("prompt".utf8))
        try await waitForLayout("first prompt") { client.session.readViewportText()?.contains("prompt") == true }
        #expect(textFrame().minY >= minimumClearance)
        #expect(abs(textFrame().maxY - fixture.window.bounds.maxY) < 1)

        client.session.receive(Data("\r\nsecond line".utf8))
        try await waitForLayout("multiline terminal reaches top edge") {
            abs(textFrame().minY - viewportTop) < 1
        }
        #expect(abs(textFrame().maxY - fixture.window.bounds.maxY) < 1)
        #expect(container.acceptsTerminalInput(at: CGPoint(x: 100, y: 1)))

        client.session.receive(Data("\u{1b}[2J\u{1b}[Hprompt".utf8))
        try await waitForLayout("cleared terminal protects first prompt again") {
            client.session.readViewportText()?.contains("second line") == false
                && textFrame().minY >= minimumClearance
        }
        #expect(abs(textFrame().maxY - fixture.window.bounds.maxY) < 1)

        let columns = Int(try #require(container.terminalGridMetrics).columns)
        let repeats = (wrappedCharacter == "x" ? columns : columns / 2) + 5
        client.session.receive(Data(String(repeating: wrappedCharacter, count: repeats).utf8))
        try await waitForLayout("soft-wrapped first line removes clearance") {
            abs(textFrame().minY - viewportTop) < 1
        }
        #expect(abs(textFrame().maxY - fixture.window.bounds.maxY) < 1)

        let rows = Int(try #require(container.terminalGridMetrics).rows)
        client.session.receive(Data((String(repeating: "\r\noutput", count: rows * 2)
                                     + "\u{1b}[2J\u{1b}[Hprompt").utf8))
        try await waitForLayout("scrollback removes clearance even with one visible line") {
            abs(textFrame().minY - viewportTop) < 1
        }
        #expect(abs(textFrame().maxY - fixture.window.bounds.maxY) < 1)
    }

    @Test("@spec IOS-6.11: While the software keyboard is visible in a fullscreen mobile terminal, the application shall reserve the measured terminal control-bar height above the keyboard; while the keyboard is hidden, floating controls shall overlay the full usable viewport.", arguments: [CGFloat(0), CGFloat(300)])
    func fullscreenCanvasReachesScreenEdges(keyboardInset: CGFloat) async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let fixture = makeFixture(client: client, keyboardInset: keyboardInset)
        defer { fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        let containerFrame = container.convert(container.bounds, to: fixture.window)
        let canvasFrame = container.snapshotScrollView.convert(container.snapshotScrollView.bounds, to: fixture.window)
        // The control bar has 34pt controls, 16pt vertical content padding,
        // and 8pt bottom padding. Hidden controls float over the full canvas.
        let expectedBottom = fixture.window.bounds.maxY - keyboardInset - (keyboardInset > 0 ? 58 : 0)

        #expect(abs(containerFrame.minY - fixture.window.bounds.minY) < 1,
                "Terminal container starts at \(containerFrame.minY), screen starts at \(fixture.window.bounds.minY)")
        #expect(abs(containerFrame.maxY - expectedBottom) < 1,
                "Terminal container ends at \(containerFrame.maxY), expected \(expectedBottom)")
        #expect(abs(canvasFrame.minY - fixture.window.bounds.minY) < 1,
                "Canvas viewport starts at \(canvasFrame.minY), leaving a top gap")
        #expect(abs(canvasFrame.maxY - expectedBottom) < 1,
                "Canvas viewport ends at \(canvasFrame.maxY), expected \(expectedBottom)")
        #expect(abs(containerFrame.width - fixture.window.bounds.width) < 1)
        #expect(abs(canvasFrame.width - fixture.window.bounds.width) < 1)
        let textFrame = container.terminalView.convert(container.terminalView.bounds, to: fixture.window)
        #expect(textFrame.minY >= fixture.host.view.safeAreaInsets.top + 68)
        #expect(abs(textFrame.maxY - expectedBottom) < 1)
    }

    @Test("@spec IPAD-2.10: While the regular-width iPad detail renders a split tree, the application shall observe keyboard frame changes once for the whole tree and derive each embedded pane's keyboard visibility from that shared observation, including a pane mounted while the keyboard is already visible.")
    func embeddedPaneFollowsSharedKeyboardObservation() async throws {
        func render(shared: KeyboardFrameObservation) async throws
            -> (window: UIWindow, client: SessionClient, frame: () -> CGRect) {
            let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
            client.start()
            try await waitForLayout("local owner") { client.isOwner }
            let fixture = makeFixture(client: client, embedded: true, sharedKeyboard: shared)
            let container = try await renderedContainer(in: fixture.host.view)
            return (fixture.window, client, {
                fixture.host.view.layoutIfNeeded()
                return container.convert(container.bounds, to: fixture.window)
            })
        }

        do {
            let visible = try await render(shared: KeyboardFrameObservation(bottomInset: 300, sequence: 1))
            defer { visible.window.isHidden = true; visible.client.stop() }
            try await waitForLayout("mounted pane lays out the keyboard control bar") {
                visible.frame().maxY < visible.window.bounds.maxY - 30
            }
        }

        let hidden = try await render(shared: KeyboardFrameObservation())
        defer { hidden.window.isHidden = true; hidden.client.stop() }
        #expect(abs(hidden.frame().maxY - hidden.window.bounds.maxY) < 1)
        let screen = UIScreen.main.bounds
        func postKeyboardFrame(height: CGFloat) {
            NotificationCenter.default.post(
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(
                    x: 0, y: screen.maxY - height, width: screen.width, height: max(height, 300)))])
        }
        postKeyboardFrame(height: 300)
        defer { postKeyboardFrame(height: 0) }
        try await Task.sleep(for: .milliseconds(300))
        #expect(abs(hidden.frame().maxY - hidden.window.bounds.maxY) < 1,
                "An embedded pane must follow its parent's keyboard observation, not its own subscription")
    }

    @Test("@spec IPAD-2.8: While the regular-width iPad detail is visible, the application shall keep workspace tabs and terminals below navigation chrome, extend the terminal tree to the bottom detail-column edge, and respect the sidebar boundary.")
    func embeddedCanvasStaysInsideTheIPadDetailColumn() async throws {
        let client = SessionClient(sessionName: "viewport", webSocketFactory: { ViewportLegacySocket() })
        let fixture = makeFixture(client: client, embedded: true)
        defer { client.stop(); fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        let containerFrame = container.convert(container.bounds, to: fixture.window)
        let canvasFrame = container.snapshotScrollView.convert(container.snapshotScrollView.bounds, to: fixture.window)

        #expect(abs(containerFrame.minX - 320) < 1)
        #expect(abs(containerFrame.maxX - fixture.window.bounds.maxX) < 1)
        #expect(abs(canvasFrame.minX - containerFrame.minX) < 1)
        #expect(abs(canvasFrame.maxX - containerFrame.maxX) < 1)
        #expect(abs(containerFrame.minY - fixture.host.view.safeAreaInsets.top) < 1)
        #expect(abs(containerFrame.maxY - fixture.window.bounds.maxY) < 1)
        #expect(abs(canvasFrame.minY - containerFrame.minY) < 1)
        #expect(abs(canvasFrame.maxY - containerFrame.maxY) < 1)
    }

    @Test("@spec IOS-5.5: While a terminal is fullscreen, the application shall display a translucent Back control with at least a 44-point tap target within the top and leading safe area, returning to the worktree list.")
    func floatingBackControlStaysBelowTheTopSafeArea() async throws {
        let fixture = makeHostingFixture(content: AnyView(GeometryReader { _ in
            Color.black.ignoresSafeArea()
                .overlay(alignment: .topLeading) {
                    TerminalFloatingGlyphButton(systemName: "chevron.left",
                                                accessibilityLabel: "Back to worktrees", action: {})
                        .background(FloatingControlFrameMarker())
                        .modifier(TerminalFloatingControlPlacement())
                }
        }))
        defer { fixture.window.isHidden = true }
        var markers: [FloatingControlFrameView] = []
        try await waitForLayout("floating Back geometry") {
            fixture.host.view.layoutIfNeeded()
            markers = descendants(of: fixture.host.view).compactMap { $0 as? FloatingControlFrameView }
            return markers.count == 1 && markers[0].bounds.width > 0 && markers[0].bounds.height > 0
        }
        let marker = try #require(markers.first)
        let backFrame = marker.convert(marker.bounds, to: fixture.window)
        let safeTop = fixture.host.view.safeAreaInsets.top
        let safeLeading = fixture.host.view.safeAreaInsets.left

        #expect(safeTop >= 40, "The rendered fixture must have a real top safe area")
        #expect(abs(backFrame.minY - (safeTop + 12)) < 1,
                "Back starts at \(backFrame.minY), expected 12pt below the safe area at \(safeTop)")
        #expect(abs(backFrame.minX - (safeLeading + 12)) < 1,
                "Back starts at \(backFrame.minX), expected 12pt after the leading safe area at \(safeLeading)")
        #expect(backFrame.width >= 44 && backFrame.height >= 44,
                "Back's rendered control is \(backFrame.size), below the 44pt minimum tap target")
        #expect(fixture.window.bounds.contains(backFrame))
    }

    @Test("@spec IPAD-2.24: While a compact Terminal sheet is visible, the application shall reserve only the keyboard overlap within its safe content bounds.", arguments: [CGFloat(0), CGFloat(300)])
    func sheetKeyboardClearance(keyboardInset: CGFloat) async throws {
        let client = SessionClient(sessionName: "sheet", webSocketFactory: { ViewportLegacySocket() })
        client.start()
        defer { client.stop() }
        try await waitForLayout("local owner") { client.isOwner }
        let terminal = SingleSessionView(step: SessionStep(host: Host(label: "Mac", baseURL: URL(string: "https://mac.local")!),
            sessionName: "sheet", title: "Shell"), navigationPath: .constant(NavigationPath()),
            isFullScreen: false, isTerminalSheet: true, initialClient: client,
            initialController: MobileTerminalControllerFactory.make(configText: "font-size = 14"),
            initialKeyboardBottomInset: keyboardInset)
        let fixture = makeHostingFixture(content: AnyView(VStack(spacing: 0) {
            Text("Terminal").frame(height: 44)
            terminal
        }.ignoresSafeArea(.keyboard)))
        defer { fixture.window.isHidden = true }
        let container = try await renderedContainer(in: fixture.host.view)
        try await Task.sleep(for: .milliseconds(150))
        fixture.host.view.layoutIfNeeded()
        let frame = container.convert(container.bounds, to: fixture.window)
        let bottomInset = fixture.host.view.safeAreaInsets.bottom
        let expectedBottom = fixture.window.bounds.maxY - max(bottomInset, keyboardInset) - (keyboardInset > 0 ? 58 : 0)
        #expect(abs(frame.maxY - expectedBottom) < 1)
        #expect(frame.minY >= fixture.host.view.safeAreaInsets.top + 44)
    }

    private func makeFixture(client: SessionClient, keyboardInset: CGFloat = 0, embedded: Bool = false, agentWorkspace: Bool = false,
                             size: CGSize? = nil, largeText: Bool = false,
                             question: String? = nil, completed: Bool = false,
                             sharedKeyboard: KeyboardFrameObservation? = nil) -> (window: UIWindow, host: UIHostingController<AnyView>) {
        let leaf = PaneLayoutNode.leaf(sessionName: "viewport", title: "Agent", attentionText: nil, isBusy: false, attentionSource: nil)
        let layout = question.map { question in
            PaneLayoutNode.split(direction: .horizontal, ratio: 0.5, left: leaf,
                right: .leaf(sessionName: "other", title: "Other agent", attentionText: question, isBusy: false, attentionSource: .agentStop))
        } ?? leaf
        let workspace = WorktreePanes(path: "/repo", displayName: "Phone header", repoDisplayName: "Repo", displayBranch: "phone-header",
            state: .running, isMainCheckout: false, prBadge: nil, stats: nil, attentionText: nil,
            layout: layout,
            sidebar: .init(id: "repo", projectID: "project", emoji: "🔥"),
            agents: [.init(id: "agent", name: "Agent", provider: "codex", status: completed ? "closed" : "running",
                sessionName: completed ? nil : "viewport", completionID: completed ? "done" : nil,
                result: completed ? "Finished" : nil, retainedSessionName: completed ? "viewport" : nil)])
        let terminal = SingleSessionView(
            step: SessionStep(host: Host(label: "Mac", baseURL: URL(string: "https://mac.local")!),
                              worktreePath: agentWorkspace ? workspace.path : nil, sessionName: "viewport", title: "Shell"),
            navigationPath: .constant(NavigationPath()), isFullScreen: !embedded,
            isEmbeddedPane: embedded, attentionWorktrees: agentWorkspace ? [workspace] : [], initialClient: client,
            initialController: MobileTerminalControllerFactory.make(configText: "font-size = 14"),
            initialKeyboardBottomInset: keyboardInset)
        let content: AnyView
        if embedded {
            content = AnyView(HStack(spacing: 0) {
                Color.gray.frame(width: 320)
                terminal.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            }.modifier(IPadTerminalDetailChrome())
                .environment(\.multiPaneKeyboardFrame, sharedKeyboard))
        } else {
            content = AnyView(terminal
                .environment(\.remoteConnectionCoordinator, agentWorkspace ? RemoteConnectionCoordinator() : nil)
                .environment(\.dynamicTypeSize, largeText ? .accessibility3 : .large))
        }
        return makeHostingFixture(content: content, embedded: embedded, size: size)
    }

    private func makeHostingFixture(content: AnyView,
                                    embedded: Bool = false, size: CGSize? = nil) -> (window: UIWindow, host: UIHostingController<AnyView>) {
        let host = UIHostingController(rootView: AnyView(content
            .environment(\.scenePhase, .inactive)
            .environment(\.accessibilityEnabled, true)
            .environment(\.horizontalSizeClass, embedded ? .regular : .compact)))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size ?? CGSize(width: embedded ? 834 : 390, height: 844)))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let nativeInsets = host.view.safeAreaInsets
        host.additionalSafeAreaInsets = UIEdgeInsets(top: max(0, 59 - nativeInsets.top), left: 0,
                                                     bottom: max(0, 34 - nativeInsets.bottom), right: 0)
        host.view.layoutIfNeeded()
        return (window, host)
    }

    private func renderedContainer(in root: UIView) async throws -> TerminalInputContainerView {
        var container: TerminalInputContainerView?
        try await waitForLayout("measured terminal cells") {
            root.layoutIfNeeded()
            container = descendants(of: root).compactMap { $0 as? TerminalInputContainerView }.first
            container?.layoutIfNeeded()
            guard let metrics = container?.terminalGridMetrics else { return false }
            return metrics.columns > 0 && metrics.rows > 0 && metrics.cellHeightPixels > 0
                && container!.snapshotScrollView.bounds.height > 0
        }
        // Let the resize callback's resulting layout settle before measuring.
        try await Task.sleep(for: .milliseconds(100))
        root.layoutIfNeeded()
        container?.layoutIfNeeded()
        return try #require(container)
    }

    private func descendants(of root: UIView) -> [UIView] {
        [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    private func accessibilityObjects(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = [], pending = [root], seen: Set<ObjectIdentifier> = []
        while let object = pending.popLast(), result.count < 4096 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            pending.append(contentsOf: (object.automationElements ?? []).compactMap { $0 as? NSObject })
            for index in 0..<max(0, min(object.accessibilityElementCount(), 128)) {
                if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
            }
        }
        return result
    }

    private func waitForLayout(_ stage: String, sourceLocation: SourceLocation = #_sourceLocation,
                               condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        // The predicate can advance UIKit layout. Finish on the ready frame
        // already observed instead of evaluating it again after the loop.
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for \(stage)", sourceLocation: sourceLocation)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private final class FloatingControlFrameView: UIView {}

private struct FloatingControlFrameMarker: UIViewRepresentable {
    func makeUIView(context: Context) -> FloatingControlFrameView {
        let view = FloatingControlFrameView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: FloatingControlFrameView, context: Context) {}
}

private final class ViewportLegacySocket: WebSocketClient, @unchecked Sendable {
    func send(_ frame: WebSocketFrame) async throws {}
    func receive() async throws -> WebSocketFrame {
        try await Task.sleep(for: .seconds(30))
        throw CancellationError()
    }
    func close() {}
}

@Suite("""
@spec IOS-6.1: While the software keyboard is visible, the application shall render a compact terminal control bar above the keyboard with Esc, Tab, sticky Ctrl, tray Shift, Ctrl-C, Ctrl-D, arrows, submit Return, literal LF, Auto-correct, and Hide Keyboard controls. The terminal key controls shall send their explicit terminal bytes through `SessionClient`. Tapping sticky Ctrl once shall arm it for the next software-keyboard letter, tapping it twice shall lock it, and libghostty shall translate Ctrl+A through Ctrl+Z to ASCII bytes `0x01` through `0x1A`. When terminal input becomes ineligible, the application shall clear sticky Ctrl and tray Shift state.
""")
@MainActor
struct MobileTerminalControlBarTests {
    @Test("the control bar keeps Tab visible and puts sticky Ctrl beside it")
    func layoutContainsTabAndStickyControl() {
        #expect(SingleSessionView.terminalControlBarItems == [
            .escape,
            .tab,
            .stickyControl,
            .shift,
            .controlC,
            .controlD,
            .navigationDivider,
            .left,
            .down,
            .up,
            .right,
            .returnDivider,
            .submitReturn,
            .literalLineFeed,
            .autocorrection,
            .hideKeyboard,
        ])
    }

    @Test("@spec IOS-6.30: When the user toggles tray Shift, the application shall retain its selection across tray key presses until toggled off, and clear it when terminal input becomes ineligible or sticky modifiers are reset.")
    func trayShiftSelectionAndReset() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        var selections: [Bool] = []
        container.onTrayShiftSelectionChange = { selections.append($0) }

        container.toggleTrayShift()
        #expect(container.isTrayShiftSelected)
        #expect(TerminalTrayKey.left.data(shift: container.isTrayShiftSelected)
            == Data("\u{1B}[1;2D".utf8))
        #expect(container.isTrayShiftSelected)
        container.toggleTrayShift()
        #expect(!container.isTrayShiftSelected)

        container.toggleTrayShift()
        container.resetStickyModifiers()
        #expect(!container.isTrayShiftSelected)
        container.toggleTrayShift()
        container.committedSoftwareInput = nil
        #expect(!container.isTrayShiftSelected)
        container.toggleTrayShift()
        #expect(!container.isTrayShiftSelected)
        #expect(selections == [true, false, true, false, true, false])

        let retainedPane = RetainedMobilePane(client: SessionClient(
            sessionName: "s",
            webSocketFactory: { ViewportLegacySocket() }
        ))
        retainedPane.container = container
        retainedPane.detachControls()
        #expect(container.onTrayShiftSelectionChange == nil)
    }

    @Test("sticky Ctrl uses libghostty for arbitrary software-keyboard letters")
    func stickyControlLettersSendAsciiControlBytes() {
        let recorder = ThreadSafeDataRecorder()
        let session = InMemoryTerminalSession(
            write: { recorder.append($0) },
            resize: { _ in }
        )
        let container = TerminalInputContainerView(frame: .zero)
        container.terminalView.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        var activations: [TerminalInputContainerView.StickyControlActivation] = []
        container.setStickyControlActivationChangeHandler { activations.append($0) }

        container.toggleStickyControlModifier()
        #expect(container.stickyControlActivation == .armed)
        container.terminalView.insertText("a")
        #expect(container.stickyControlActivation == .inactive)

        container.toggleStickyControlModifier()
        container.terminalView.insertText("j")

        container.toggleStickyControlModifier()
        container.terminalView.insertText("z")

        #expect(recorder.values == [Data([0x01]), Data([0x0A]), Data([0x1A])])
        #expect(activations == [
            .armed, .inactive,
            .armed, .inactive,
            .armed, .inactive,
        ])
    }

    @Test("normal typing does not disconnect the sticky Ctrl state observer")
    func ordinaryTextKeepsStickyControlObserverAttached() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        var activations: [TerminalInputContainerView.StickyControlActivation] = []
        container.setStickyControlActivationChangeHandler { activations.append($0) }

        container.terminalView.insertText("x")
        container.toggleStickyControlModifier()

        #expect(activations == [.armed])
        #expect(container.stickyControlActivation == .armed)
    }

    @Test("double-tapping sticky Ctrl locks it until reset")
    func stickyControlDoubleTapLocks() {
        let container = TerminalInputContainerView(frame: .zero)
        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})

        // The renderer uses a real 300 ms double-tap window and exposes no
        // clock override. A simulator can preempt these synchronous calls
        // long enough to produce two single taps. Retry only that measured
        // case, never an incorrect transition inside the double-tap window.
        for attempt in 0..<5 {
            container.resetStickyModifiers()
            let start = ContinuousClock.now
            container.toggleStickyControlModifier()
            container.toggleStickyControlModifier()
            let elapsed = start.duration(to: .now)
            if elapsed >= .milliseconds(300),
               container.stickyControlActivation == .inactive,
               attempt < 4 {
                continue
            }
            break
        }
        #expect(container.stickyControlActivation == .locked)

        container.committedSoftwareInput = nil
        #expect(container.stickyControlActivation == .inactive)

        container.committedSoftwareInput = .init(insertText: { _ in }, deleteBackward: {})
        container.toggleStickyControlModifier()
        container.resetStickyModifiers()
        #expect(container.stickyControlActivation == .inactive)
    }
}

private final class ThreadSafeDataRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Data] = []

    var values: [Data] {
        lock.withLock { storage }
    }

    func append(_ value: Data) {
        lock.withLock { storage.append(value) }
    }
}
#endif
