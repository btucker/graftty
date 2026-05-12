import AppKit
import Foundation
import GhosttyKit
import GrafttyKit
import Testing
@testable import Graftty

@MainActor
@Suite("SurfaceHandle host-managed zmx cutover")
struct SurfaceHandleHostManagedTests {
    @Test func zmxAvailableUsesHostManagedBackendWithoutCommandOrInitialInput() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: Self.spawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _ in backend }
        )

        #expect(handle != nil)
        #expect(harness.capturedConfigs.count == 1)
        let captured = try #require(harness.capturedConfigs.first)
        #expect(captured.backend == GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(captured.receiveUserdata != nil)
        #expect(captured.receiveBuffer != nil)
        #expect(captured.receiveResize != nil)
        #expect(captured.command == nil)
        #expect(captured.initialInput == nil)
        #expect(backend.startCount == 1)
    }

    @Test func directShellFallbackPreservesExtraInitialInput() throws {
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: nil,
            extraInitialInput: "nvim README.md\r",
            surfaceFactory: harness.factory
        )

        #expect(handle != nil)
        let captured = try #require(harness.capturedConfigs.first)
        #expect(captured.backend != GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED)
        #expect(captured.initialInput == "nvim README.md\r")
    }

    @Test func zmxBackedExtraInitialInputWritesThroughBackendAfterStart() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: Self.spawnConfiguration(),
            extraInitialInput: "nvim Sources/main.swift\r",
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _ in backend }
        )

        #expect(handle != nil)
        let captured = try #require(harness.capturedConfigs.first)
        #expect(captured.initialInput == nil)
        #expect(backend.startCount == 1)
        #expect(backend.writes == [Data("nvim Sources/main.swift\r".utf8)])
    }

    @Test func typeTextUsesBackendForZmxBackedSurface() throws {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: Self.spawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _ in backend }
        ))

        handle.typeText("abc")

        #expect(backend.writes == [Data("abc".utf8)])
        #expect(harness.textWrites.isEmpty)
    }

    @Test func typeTextKeepsGhosttyTextForNonZmxSurface() throws {
        let harness = SurfaceHandleTestHarness(surface: fakeSurface())
        let handle = try #require(SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: nil,
            surfaceFactory: harness.factory
        ))

        handle.typeText("abc")

        #expect(harness.textWrites == [Data("abc".utf8)])
    }

    @Test func surfaceNewFailureDoesNotStartBackendAndReleasesBackendState() {
        let backend = FakeSurfaceHandleZmxBackend()
        let harness = SurfaceHandleTestHarness(surface: nil)

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: Self.spawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _ in backend }
        )

        #expect(handle == nil)
        #expect(backend.startCount == 0)
        #expect(backend.closeCount == 1)
        #expect(backend.releaseCount == 1)
        #expect(harness.freeCalls.isEmpty)
    }

    @Test func backendStartFailureReportsDiagnosticAndNonzeroExitWithoutImmediateFree() {
        struct ForcedStartFailure: Error {}

        let backend = FakeSurfaceHandleZmxBackend(startError: ForcedStartFailure())
        let surface = fakeSurface()
        let harness = SurfaceHandleTestHarness(surface: surface)

        let handle = SurfaceHandle(
            terminalID: Self.terminalID(),
            app: fakeApp(),
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            zmxSpawnConfiguration: Self.spawnConfiguration(),
            surfaceFactory: harness.factory,
            zmxBackendFactory: { _ in backend }
        )

        #expect(handle != nil)
        #expect(backend.startCount == 1)
        #expect(backend.closeCount == 1)
        #expect(backend.releaseCount == 0)
        #expect(harness.freeCalls.isEmpty)
        #expect(harness.writeBufferCalls.count == 1)
        #expect(
            String(data: harness.writeBufferCalls[0].data, encoding: .utf8)?
                .contains("zmx attach failed") == true
        )
        #expect(harness.processExitCalls == [
            ProcessExitCall(surface: surface, exitCode: 1)
        ])
    }

    private static func terminalID() -> TerminalID {
        TerminalID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!)
    }

    private static func spawnConfiguration() -> ZmxSpawnConfiguration {
        ZmxSpawnConfiguration.make(
            launcher: ZmxLauncher(
                executable: URL(fileURLWithPath: "/tmp/zmx"),
                zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir", isDirectory: true)
            ),
            paneID: Self.terminalID().id,
            worktreePath: "/tmp/worktree",
            socketPath: "/tmp/graftty.sock",
            processEnv: ["SHELL": "/bin/zsh", "PATH": "/usr/bin"],
            bundleURL: URL(fileURLWithPath: "/Applications/Graftty.app"),
            ghosttyResourcesDir: nil,
            agentHooksDisabled: true,
            agentHooksRoot: URL(fileURLWithPath: "/tmp/hooks", isDirectory: true)
        )
    }
}

@MainActor
private final class SurfaceHandleTestHarness {
    private let surface: ghostty_surface_t?
    var capturedConfigs: [CapturedSurfaceConfig] = []
    var freeCalls: [ghostty_surface_t] = []
    var textWrites: [Data] = []
    var writeBufferCalls: [SurfaceWriteBufferCall] = []
    var processExitCalls: [ProcessExitCall] = []

    init(surface: ghostty_surface_t?) {
        self.surface = surface
    }

    var factory: SurfaceHandleGhosttySurfaceFactory {
        SurfaceHandleGhosttySurfaceFactory(
            create: { [weak self] _, config in
                self?.capturedConfigs.append(CapturedSurfaceConfig(config.pointee))
                return self?.surface
            },
            free: { [weak self] surface in
                self?.freeCalls.append(surface)
            },
            text: { [weak self] _, ptr, count in
                self?.textWrites.append(Data(bytes: ptr, count: Int(count)))
            },
            writeBuffer: { [weak self] surface, ptr, count in
                self?.writeBufferCalls.append(
                    SurfaceWriteBufferCall(
                        surface: surface,
                        data: Data(bytes: ptr, count: Int(count))
                    )
                )
            },
            processExit: { [weak self] surface, exitCode, _ in
                self?.processExitCalls.append(
                    ProcessExitCall(surface: surface, exitCode: exitCode)
                )
            }
        )
    }
}

private struct SurfaceWriteBufferCall: Equatable {
    let surface: ghostty_surface_t
    let data: Data
}

private struct ProcessExitCall: Equatable {
    let surface: ghostty_surface_t
    let exitCode: UInt32
}

private struct CapturedSurfaceConfig {
    let backend: ghostty_surface_io_backend_e
    let command: String?
    let initialInput: String?
    let receiveUserdata: UnsafeMutableRawPointer?
    let receiveBuffer: ghostty_surface_receive_buffer_cb?
    let receiveResize: ghostty_surface_receive_resize_cb?

    init(_ config: ghostty_surface_config_s) {
        backend = config.backend
        command = config.command.map { String(cString: $0) }
        initialInput = config.initial_input.map { String(cString: $0) }
        receiveUserdata = config.receive_userdata
        receiveBuffer = config.receive_buffer
        receiveResize = config.receive_resize
    }
}

private final class FakeSurfaceHandleZmxBackend: SurfaceHandleZmxBackend {
    private let startError: Error?
    private(set) var startCount = 0
    private(set) var closeCount = 0
    private(set) var releaseCount = 0
    private(set) var writes: [Data] = []

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func configure(_ config: inout ghostty_surface_config_s) {
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = UnsafeMutableRawPointer(bitPattern: 0xCAFE)
        config.receive_buffer = HostManagedZmxBackend.receiveBufferCallback
        config.receive_resize = HostManagedZmxBackend.receiveResizeCallback
    }

    func start(surface: ghostty_surface_t) throws {
        startCount += 1
        if let startError {
            throw startError
        }
    }

    func write(_ data: Data) throws {
        writes.append(data)
    }

    func close() {
        closeCount += 1
    }

    func releaseReceiveUserdataAfterSurfaceFree() {
        releaseCount += 1
    }
}

private func fakeApp() -> ghostty_app_t {
    UnsafeMutableRawPointer(bitPattern: 0x1000)!
}

private func fakeSurface() -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: 0x2000)!
}
