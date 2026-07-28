import Foundation
import GrafttyProtocol
import GrafttyRemoteClient
import Testing
@testable import Graftty

@Suite("RemoteMacPaneEnvironment")
struct RemoteMacPaneEnvironmentTests {
    @Test("builder opens panes-state and pane-control")
    func builderOpensPanesAndControl() async throws {
        let panesDriver = RecordingPanesStateDriver()
        let controlDriver = RecordingPaneControlDriver()
        let remoteHost = PaneEnvironmentHost(
            panesDriver: panesDriver,
            controlDriver: controlDriver
        )

        let environment = await RemoteMacPaneEnvironment.build(remoteHost: remoteHost)

        #expect(environment.worktreePanesStore != nil)
        #expect(environment.paneControlClient != nil)
        #expect(panesDriver.openCount == 1)
        #expect(controlDriver.openCount == 1)
    }

    @Test("builder returns empty when panes-state fails to open")
    func builderReturnsEmptyWhenPanesStateFails() async throws {
        let remoteHost = PaneEnvironmentHost(
            panesDriver: ThrowingPanesStateDriver(),
            controlDriver: RecordingPaneControlDriver()
        )

        let environment = await RemoteMacPaneEnvironment.build(remoteHost: remoteHost)

        #expect(environment.isEmpty)
    }

    @Test("builder closes panes-state when pane-control fails after subscribe")
    func builderClosesPanesStateWhenPaneControlFails() async throws {
        let panesDriver = RecordingPanesStateDriver()
        let remoteHost = PaneEnvironmentHost(
            panesDriver: panesDriver,
            controlDriver: ThrowingPaneControlDriver()
        )

        let environment = await RemoteMacPaneEnvironment.build(remoteHost: remoteHost)

        #expect(environment.isEmpty)
        #expect(panesDriver.openCount == 1)
        #expect(panesDriver.closeCount == 1)
    }
}

private actor PaneEnvironmentHost: RemoteMacPaneEnvironmentHost {
    private let panesDriver: any PanesStateChannelDriver
    private let controlDriver: any PaneControlChannelDriver

    init(
        panesDriver: any PanesStateChannelDriver,
        controlDriver: any PaneControlChannelDriver
    ) {
        self.panesDriver = panesDriver
        self.controlDriver = controlDriver
    }

    func makePanesStateDriver(
        onSnapshot: @escaping @Sendable ([WorktreePanes]) async -> Void,
        onClosed: @escaping @Sendable (String) async -> Void
    ) async throws -> any PanesStateChannelDriver {
        panesDriver
    }

    func makePaneControlDriver() async throws -> any PaneControlChannelDriver {
        controlDriver
    }
}

private final class RecordingPanesStateDriver: PanesStateChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var _openCount = 0

    var openCount: Int {
        lock.withLock { _openCount }
    }
    private var _closeCount = 0

    var closeCount: Int {
        lock.withLock { _closeCount }
    }

    func open() async throws {
        lock.withLock { _openCount += 1 }
    }

    func close() {
        lock.withLock { _closeCount += 1 }
    }
}

private final class RecordingPaneControlDriver: PaneControlChannelDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var _openCount = 0

    var openCount: Int {
        lock.withLock { _openCount }
    }

    func open() async throws {
        lock.withLock { _openCount += 1 }
    }

    func close() {}

    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        .ok
    }
}

private struct ThrowingPanesStateDriver: PanesStateChannelDriver {
    func open() async throws {
        throw NSError(domain: "RemoteMacPaneEnvironmentTests", code: 1)
    }

    func close() {}
}

private struct ThrowingPaneControlDriver: PaneControlChannelDriver {
    func open() async throws {
        throw NSError(domain: "RemoteMacPaneEnvironmentTests", code: 2)
    }

    func close() {}

    func send(_ request: PaneControlRequest) async throws -> PaneControlResponse {
        .error(code: "unopened", message: "test driver")
    }
}
