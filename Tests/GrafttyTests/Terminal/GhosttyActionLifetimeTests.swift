import AppKit
import Foundation
import GhosttyKit
import GrafttyKit
import Testing
@testable import Graftty

@MainActor
@Suite(.serialized)
struct GhosttyActionLifetimeTests {
    @Test("@spec TERM-11.22: When an off-main Ghostty action reaches the main queue after its surface is closed or replaced, the application shall drop the action without reading C surface state or routing it to a replacement surface.")
    func closedSurfaceDropsQueuedAction() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        var handle: SurfaceHandle? = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(try #require(handle), for: id)
        // The factory models allocation/free without giving C any surface
        // state to read. Deferred delivery must use only Swift identity.
        var deliveries: [PaneSlotID] = []
        manager.onCloseRequest = { deliveries.append($0) }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CLOSE_TAB
        enqueue(manager, surface: fakeSurface(), action: action)
        manager.destroySurface(terminalID: id)
        handle = nil
        #expect(harness.freeCalls.count == 1)
        await drainMainQueue()
        #expect(harness.freeCalls.count == 1)
        #expect(deliveries.isEmpty)
    }

    @Test func replacementAtSameAddressDoesNotReceiveOldAction() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        var handle: SurfaceHandle? = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(try #require(handle), for: id)
        var deliveries = 0
        manager.onCloseRequest = { _ in deliveries += 1 }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CLOSE_TAB
        enqueue(manager, surface: fakeSurface(), action: action)
        manager.destroySurface(terminalID: id)
        handle = nil
        let replacement = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(replacement, for: id)
        await drainMainQueue()
        #expect(deliveries == 0)
        enqueue(manager, surface: fakeSurface(), action: action)
        await drainMainQueue()
        #expect(deliveries == 1)
    }

    @Test("@spec TERM-11.23: When a Ghostty action is deferred to the main queue, the application shall copy each consumed borrowed payload before the callback returns and preserve live-surface and app-scoped routing.")
    func titleIsOwnedBeforeCallbackReturns() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(handle, for: id)
        let title = try #require(strdup("before"))
        defer { free(title) }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_SET_TITLE
        action.action.set_title.title = UnsafePointer(title)
        enqueue(manager, surface: fakeSurface(), action: action)
        "after!".withCString { _ = memcpy(title, $0, 7) }
        await drainMainQueue()
        #expect(manager.displayTitle(for: id) == "before")
    }

    @Test func liveSurfaceRoutesCommandAndScalarPayload() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(handle, for: id)
        var finished: [(PaneSlotID, Int16, UInt64)] = []
        manager.onCommandFinished = { finished.append(($0, $1, $2)) }
        var command: HostManagedPaneCommand?
        manager.registerHostManagedPaneCommandHandler(for: id) { command = $0 }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_COMMAND_FINISHED
        action.action.command_finished.exit_code = -1
        action.action.command_finished.duration = 123456789
        enqueue(manager, surface: fakeSurface(), action: action)
        action.tag = GHOSTTY_ACTION_GOTO_SPLIT
        action.action.goto_split = GHOSTTY_GOTO_SPLIT_PREVIOUS
        enqueue(manager, surface: fakeSurface(), action: action)
        #expect(finished.isEmpty)
        #expect(command == nil)
        await drainMainQueue()
        #expect(finished.count == 1)
        #expect(finished.first?.0 == id)
        #expect(finished.first?.1 == -1)
        #expect(finished.first?.2 == 123456789)
        #expect(command == .focusOrder(forward: false))
    }

    @Test func appActionsSurviveWithoutAnySurface() async {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        var reloads = 0
        var opens = 0
        manager.onReloadConfig = { reloads += 1 }
        manager.onOpenConfig = { opens += 1 }
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
        post { manager.receiveGhosttyAction(target: target, action: action) }
        action.tag = GHOSTTY_ACTION_OPEN_CONFIG
        post { manager.receiveGhosttyAction(target: target, action: action) }
        #expect(reloads == 0)
        #expect(opens == 0)
        await drainMainQueue()
        #expect(reloads == 1)
        #expect(opens == 1)
    }

    @Test func retainedEvictedHandleCannotDeliverSurfaceScopedGlobalAction() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(handle, for: id)
        var reloads = 0
        manager.onReloadConfig = { reloads += 1 }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
        enqueue(manager, surface: fakeSurface(), action: action)
        manager.evictSurface(terminalID: id, forRetry: true)
        await drainMainQueue()
        #expect(reloads == 0)
        #expect(harness.freeCalls.isEmpty, "the retained allocation must not imply current pane membership")
        withExtendedLifetime(handle) {}
    }

    @Test func oldDestructorCannotUnregisterReplacement() async throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        var old: SurfaceHandle? = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(try #require(old), for: id)
        let replacement = try makeHandle(manager, id: id, harness: harness)
        manager.insertSurfaceForTesting(replacement, for: id)
        old = nil
        #expect(harness.freeCalls.count == 1)
        var deliveries = 0
        manager.onCloseRequest = { _ in deliveries += 1 }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_CLOSE_TAB
        enqueue(manager, surface: fakeSurface(), action: action)
        await drainMainQueue()
        #expect(deliveries == 1)
    }

    @Test func synchronousConstructionTitleAndLiveTitleArePreserved() throws {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        let id = PaneSlotID()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        var factory = harness.factory
        let create = factory.create
        factory.create = { [weak manager] app, config in
            guard let manager else { return nil }
            "startup".withCString { title in
                var target = ghostty_target_s()
                target.tag = GHOSTTY_TARGET_SURFACE
                target.target.surface = fakeSurface()
                var action = ghostty_action_s()
                action.tag = GHOSTTY_ACTION_SET_TITLE
                action.action.set_title.title = title
                manager.receiveGhosttyAction(target: target, action: action)
                #expect(manager.displayTitle(for: id) == "startup")
            }
            return create(app, config)
        }
        let handle = try #require(SurfaceHandle(terminalID: id, app: fakeApp(), worktreePath: "/tmp",
            socketPath: manager.socketPath, zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            terminalManager: manager, surfaceFactory: factory,
            zmxBackendFactory: { _, _, _, _ in FakeSurfaceHandleZmxBackend() }))
        manager.insertSurfaceForTesting(handle, for: id)
        "live".withCString { title in
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = fakeSurface()
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_SET_TITLE
            action.action.set_title.title = title
            manager.receiveGhosttyAction(target: target, action: action)
            #expect(manager.displayTitle(for: id) == "live", "main-thread actions remain synchronous")
        }
    }

    @Test func borrowedPWDURLAndNotificationAreOwned() async throws {
        let bridge = GhosttyActionBridge()
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_APP
        var delivered: [GhosttyOwnedAction] = []
        let pointer = try #require(strdup("before"))
        defer { free(pointer) }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_PWD
        action.action.pwd.pwd = UnsafePointer(pointer)
        post { bridge.receive(target: target, action: action) { _, action in delivered.append(action) } }
        action.tag = GHOSTTY_ACTION_DESKTOP_NOTIFICATION
        action.action.desktop_notification.title = UnsafePointer(pointer)
        action.action.desktop_notification.body = UnsafePointer(pointer)
        post { bridge.receive(target: target, action: action) { _, action in delivered.append(action) } }
        // URL is a length-delimited UTF-8 slice, not a C string. Include a
        // multibyte character and omit a terminating NUL from its storage.
        var bytes = Array("https://example.test/é".utf8)
        bytes.withUnsafeMutableBytes { buffer in
            var urlAction = ghostty_action_s()
            urlAction.tag = GHOSTTY_ACTION_OPEN_URL
            urlAction.action.open_url.url = UnsafePointer(buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
            urlAction.action.open_url.len = UInt(buffer.count)
            post { bridge.receive(target: target, action: urlAction) { _, action in delivered.append(action) } }
            buffer.initializeMemory(as: UInt8.self, repeating: 0x78)
        }
        "after!".withCString { _ = memcpy(pointer, $0, 7) }
        #expect(delivered.isEmpty)
        await drainMainQueue()
        try #require(delivered.count == 3)
        if case .pwd(let pwd) = delivered[0] { #expect(pwd == "before") }
        else { Issue.record("PWD was not delivered") }
        if case let .desktopNotification(title, body) = delivered[1] {
            #expect(title == "before")
            #expect(body == "before")
        } else { Issue.record("notification was not delivered") }
        if case .openURL(let url) = delivered[2] { #expect(url == "https://example.test/é") }
        else { Issue.record("URL was not delivered") }
    }

    @Test func unknownSurfaceTargetIsDropped() async {
        let manager = TerminalManager(socketPath: "/tmp/graftty-action-lifetime.sock")
        var reloads = 0
        manager.onReloadConfig = { reloads += 1 }
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
        enqueue(manager, surface: fakeSurface(), action: action)
        await drainMainQueue()
        #expect(reloads == 0)
    }

    @Test func invalidURLAndUnusedBorrowedPayloadAreIgnored() {
        var action = ghostty_action_s()
        action.tag = GHOSTTY_ACTION_OPEN_URL
        var bytes: [UInt8] = [0xFF]
        bytes.withUnsafeMutableBytes { buffer in
            action.action.open_url.url = UnsafePointer(buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
            action.action.open_url.len = 1
            #expect(GhosttyOwnedAction(action) == nil)
        }
        action.tag = GHOSTTY_ACTION_MOUSE_OVER_LINK
        // Unhandled borrowed payloads must never be decoded or retained.
        // A deliberately invalid address: it must never be dereferenced.
        action.action.mouse_over_link.url = UnsafePointer<CChar>(bitPattern: 1)!
        #expect(GhosttyOwnedAction(action) == nil)
    }

    @Test(arguments: [false, true])
    func nestedConstructionRestoresOuterTarget(innerSucceeds: Bool) {
        let bridge = GhosttyActionBridge()
        let outer = GhosttyActionBridge.SurfaceIdentity(terminalID: PaneSlotID())
        let inner = GhosttyActionBridge.SurfaceIdentity(terminalID: PaneSlotID())
        let innerSurface = UnsafeMutableRawPointer(bitPattern: 0x3000)!
        var identities: [GhosttyActionBridge.SurfaceIdentity] = []
        func emit(_ surface: ghostty_surface_t) {
            var target = ghostty_target_s()
            target.tag = GHOSTTY_TARGET_SURFACE
            target.target.surface = surface
            var action = ghostty_action_s()
            action.tag = GHOSTTY_ACTION_RELOAD_CONFIG
            bridge.receive(target: target, action: action) { target, _ in
                if case .surface(let identity) = target { identities.append(identity) }
            }
        }
        _ = bridge.withSurfaceCreation(outer) {
            emit(fakeSurface())
            _ = bridge.withSurfaceCreation(inner) {
                emit(innerSurface)
                return innerSucceeds ? innerSurface : nil
            }
            emit(fakeSurface())
            return fakeSurface()
        }
        #expect(identities == [outer, inner, outer])
        emit(innerSurface)
        #expect(identities.count == (innerSucceeds ? 4 : 3))
        if innerSucceeds { #expect(identities.last == inner) }
        bridge.unregister(fakeSurface(), identity: outer)
        emit(fakeSurface())
        #expect(identities.count == (innerSucceeds ? 4 : 3), "construction identity must not leak into later callbacks")
    }

    private func post(_ callback: @escaping () -> Void) {
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            callback()
            posted.signal()
        }
        // Occupy main until the callback returns, then close or mutate before delivery.
        #expect(posted.wait(timeout: .now() + 2) == .success)
    }

    private func makeHandle(_ manager: TerminalManager, id: PaneSlotID,
                            harness: SurfaceHandleTestHarness) throws -> SurfaceHandle {
        try #require(SurfaceHandle(terminalID: id, app: fakeApp(), worktreePath: "/tmp",
            socketPath: manager.socketPath, zmxSpawnConfiguration: testSurfaceHandleSpawnConfiguration(),
            terminalManager: manager, surfaceFactory: harness.factory,
            zmxBackendFactory: { _, _, _, _ in FakeSurfaceHandleZmxBackend() }))
    }

    private func enqueue(_ manager: TerminalManager, surface: ghostty_surface_t,
                         action: ghostty_action_s) {
        var target = ghostty_target_s()
        target.tag = GHOSTTY_TARGET_SURFACE
        target.target.surface = surface
        post { manager.receiveGhosttyAction(target: target, action: action) }
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
