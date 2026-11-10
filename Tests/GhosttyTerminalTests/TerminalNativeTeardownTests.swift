@testable import GhosttyTerminal
import Foundation
import GhosttyKit
import Testing
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if !canImport(UIKit) && canImport(AppKit)
@MainActor
struct TerminalNativeTeardownTests {
    @Test(arguments: [false, true])
    func fullNativeMailboxIsDrainedWithCallbacksSilenced(rebuildDuringDrain: Bool) async throws {
        await GhosttySurfaceHarness.acquireTurn()
        defer { GhosttySurfaceHarness.releaseTurn() }
        try check_fullNativeMailboxIsDrainedWithCallbacksSilenced(rebuildDuringDrain: rebuildDuringDrain)
    }

    private func check_fullNativeMailboxIsDrainedWithCallbacksSilenced(rebuildDuringDrain: Bool) throws {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in }, surfaceWrite: { raw, data in
            started.signal()
            writeNative(raw, data)
            // This C access is still inside the writer's lifetime barrier.
            _ = ghostty_surface_size(raw)
            finished.signal()
        })
        let (view, controller, coordinator) = makeNativeCoordinator(session: session)
        let originalSurface = try #require(coordinator.surface)
        defer { coordinator.freeSurface() }
        let delegate = TeardownTitleDelegate()
        coordinator.delegate = delegate
        controller.tick()
        delegate.titles = 0
        if rebuildDuringDrain {
            var requestedRebuild = false
            // Stand in for a callback from another bridge on this app. The
            // retiring bridge itself is silent, but other delegates still run.
            session.setSurface(originalSurface.rawValue, processMailbox: {
                if !requestedRebuild {
                    requestedRebuild = true
                    coordinator.configuration.fontSize = 18
                    #expect(coordinator.surface === originalSurface)
                }
                controller.tick()
            })
        }

        // Far more OSC titles than the native app mailbox's 64 slots.
        session.receive(String(repeating: "\u{1b}]2;teardown\u{7}", count: 1024))
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        let start = ProcessInfo.processInfo.systemUptime
        coordinator.freeSurface()
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(session.currentSurface == nil)
        #expect(coordinator.surface == nil)
        #expect(controller.retainedBridgeCount == 0)
        #expect(delegate.titles == 0)
        controller.tick()
        #expect(delegate.titles == 0)
        if rebuildDuringDrain {
            #expect(coordinator.testHooks_pendingRebuild)
            coordinator.rebuildIfReady()
            #expect(coordinator.surface != nil)
            #expect(coordinator.surface !== originalSurface)
            #expect(!coordinator.testHooks_pendingRebuild)
        }
        withExtendedLifetime(view) {}
    }

    @Test
    func creationKeepsItsOriginalSessionWhenACallbackChangesTheBackend() async throws {
        await GhosttySurfaceHarness.acquireTurn()
        defer { GhosttySurfaceHarness.releaseTurn() }
        try check_creationKeepsItsOriginalSessionWhenACallbackChangesTheBackend()
    }

    private func check_creationKeepsItsOriginalSessionWhenACallbackChangesTheBackend() throws {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in }, surfaceWrite: { raw, data in
            started.signal()
            writeNative(raw, data)
            finished.signal()
        })
        let otherSession = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let (oldView, oldController, oldCoordinator) = makeNativeCoordinator(session: session)
        let (newView, newController, newCoordinator) = makeNativeCoordinator(session: session, installController: false)
        defer {
            newCoordinator.freeSurface()
            oldCoordinator.freeSurface()
            withExtendedLifetime((oldView, newView)) {}
        }
        let oldRaw = try #require(oldCoordinator.surface?.rawValue)
        var changedBackend = false
        session.setSurface(oldRaw, processMailbox: {
            if !changedBackend {
                changedBackend = true
                newCoordinator.configuration = .init(backend: .inMemory(otherSession))
                #expect(newCoordinator.surface == nil)
            }
            oldController.tick()
        })
        session.receive(String(repeating: "\u{1b}]2;replace\u{7}", count: 1024))
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)

        newCoordinator.controller = newController
        let newRaw = try #require(newCoordinator.surface?.rawValue)
        #expect(session.currentSurface == newRaw)
        #expect(otherSession.currentSurface == nil)
        #expect(newController.retainedBridgeCount == 1)
        #expect(newCoordinator.testHooks_pendingRebuild)
        // Rescue a leaked recursive creation when running against RED.
        let leakedRaw = otherSession.currentSurface
        defer {
            if let leakedRaw, leakedRaw != newRaw { ghostty_surface_free(leakedRaw) }
            session.clearSurface(ifMatches: session.currentSurface)
        }
        newCoordinator.freeSurface()
        #expect(session.currentSurface == nil)
        #expect(otherSession.currentSurface == nil)
        #expect(newController.retainedBridgeCount == 0)
    }

    @Test(arguments: [1, 2, 4, 8])
    func teardownUnderUnrelatedContinuousTitleTraffic(producerCount: Int) async throws {
        await GhosttySurfaceHarness.acquireTurn()
        defer { GhosttySurfaceHarness.releaseTurn() }
        try check_teardownUnderUnrelatedContinuousTitleTraffic(producerCount: producerCount)
    }

    private func check_teardownUnderUnrelatedContinuousTitleTraffic(producerCount: Int) throws {
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let session = InMemoryTerminalSession(write: { _ in }, resize: { _ in }, surfaceWrite: { raw, data in
            started.signal()
            writeNative(raw, data)
            finished.signal()
        })
        let (view, controller, coordinator) = makeNativeCoordinator(session: session)
        let stop = TeardownValues<Bool>()
        let stopped = DispatchSemaphore(value: 0)
        var producers: [(AnyObject, TerminalController, TerminalSurfaceCoordinator)] = []
        let packet = Data(String(repeating: "\u{1b}]2;traffic\u{7}", count: 256).utf8)
        for _ in 0..<producerCount {
            let producer = InMemoryTerminalSession(write: { _ in }, resize: { _ in }, surfaceWrite: writeNative)
            producers.append(makeNativeCoordinator(session: producer, sharedController: controller))
            DispatchQueue.global().async {
                while stop.values.isEmpty {
                    producer.receive(packet)
                    producer.waitForPendingOutput()
                }
                stopped.signal()
            }
        }
        // Bound the stress source independently of the main-thread pump.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { stop.append(true) }
        defer {
            stop.append(true)
            coordinator.freeSurface()
            for (_, _, other) in producers { other.freeSurface() }
            for _ in 0..<producerCount { _ = stopped.wait(timeout: .now() + 1) }
            withExtendedLifetime((view, producers)) {}
        }
        session.receive(String(repeating: "\u{1b}]2;retiring\u{7}", count: 1024))
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        let start = ProcessInfo.processInfo.systemUptime
        coordinator.freeSurface()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("Teardown stress: \(producerCount) continuous title producers, \(elapsed) seconds")
        #expect(elapsed < 1)
    }
}

private func writeNative(_ raw: ghostty_surface_t, _ data: Data) {
    data.withUnsafeBytes { bytes in
        ghostty_surface_write_buffer(raw, bytes.bindMemory(to: UInt8.self).baseAddress!, UInt(data.count))
    }
}

@MainActor
private final class TeardownTitleDelegate: TerminalSurfaceTitleDelegate {
    var titles = 0
    func terminalDidChangeTitle(_ title: String) { titles += 1 }
}

@MainActor
private func makeNativeCoordinator(
    session: InMemoryTerminalSession,
    installController: Bool = true,
    sharedController: TerminalController? = nil
) -> (AnyObject, TerminalController, TerminalSurfaceCoordinator) {
    #if canImport(UIKit)
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    #elseif canImport(AppKit)
        _ = NSApplication.shared
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        view.wantsLayer = true
    #endif
    let controller = sharedController ?? TerminalController()
    let coordinator = TerminalSurfaceCoordinator()
    coordinator.isAttached = { true }
    coordinator.viewSize = { (600, 400) }
    coordinator.platformSetup = { config in
        #if canImport(UIKit)
            config.platform_tag = GHOSTTY_PLATFORM_IOS
            config.platform.ios.uiview = Unmanaged.passUnretained(view).toOpaque()
        #elseif canImport(AppKit)
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform.macos.nsview = Unmanaged.passUnretained(view).toOpaque()
        #endif
    }
    coordinator.configuration = .init(backend: .inMemory(session))
    if installController { coordinator.controller = controller }
    return (view, controller, coordinator)
}

#endif
