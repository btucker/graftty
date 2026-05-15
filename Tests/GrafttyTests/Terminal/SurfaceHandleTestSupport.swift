import AppKit
import Foundation
import GhosttyKit
import GrafttyKit
import Testing
@testable import Graftty

extension ghostty_surface_size_s {
    static let zero = ghostty_surface_size_s(
        columns: 0, rows: 0, width_px: 0, height_px: 0,
        cell_width_px: 0, cell_height_px: 0
    )

    /// Canonical fixture for tests that need a representative non-zero
    /// grid (132×43 cells at 12×16 px). Reused across MEM-1.6..1.8
    /// coverage so cell metrics don't drift between assertions.
    static let testSize132x43 = ghostty_surface_size_s(
        columns: 132, rows: 43, width_px: 1584, height_px: 688,
        cell_width_px: 12, cell_height_px: 16
    )
}

@MainActor
final class SurfaceHandleTestHarness {
    private let surface: ghostty_surface_t?
    var capturedConfigs: [CapturedSurfaceConfig] = []
    var freeCalls: [ghostty_surface_t] = []
    var textWrites: [Data] = []
    var writeBufferCalls: [SurfaceWriteBufferCall] = []
    var processExitCalls: [ProcessExitCall] = []
    var setSizeCalls: [SetSizeCall] = []
    var requestCloseCalls: [ghostty_surface_t] = []
    var sizeStub: ghostty_surface_size_s = .zero

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
            },
            size: { [weak self] _ in
                self?.sizeStub ?? .zero
            },
            setSize: { [weak self] surface, w, h in
                self?.setSizeCalls.append(SetSizeCall(surface: surface, width: w, height: h))
            },
            requestClose: { [weak self] surface in
                self?.requestCloseCalls.append(surface)
            }
        )
    }
}

struct SetSizeCall: Equatable {
    let surface: ghostty_surface_t
    let width: UInt32
    let height: UInt32
}

struct SurfaceWriteBufferCall: Equatable {
    let surface: ghostty_surface_t
    let data: Data
}

struct ProcessExitCall: Equatable {
    let surface: ghostty_surface_t
    let exitCode: UInt32
}

struct CapturedSurfaceConfig {
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

final class FakeSurfaceHandleZmxBackend: SurfaceHandleZmxBackend {
    private let startError: Error?
    private let setSizeCountSource: () -> Int
    private(set) var startCount = 0
    private(set) var closeCount = 0
    private(set) var releaseCount = 0
    private(set) var writes: [Data] = []
    private(set) var observedSetSizeCountAtStart = 0

    init(startError: Error? = nil, setSizeCountSource: @escaping () -> Int = { 0 }) {
        self.startError = startError
        self.setSizeCountSource = setSizeCountSource
    }

    func configure(_ config: inout ghostty_surface_config_s) {
        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = UnsafeMutableRawPointer(bitPattern: 0xCAFE)
        config.receive_buffer = HostManagedZmxBackend.receiveBufferCallback
        config.receive_resize = HostManagedZmxBackend.receiveResizeCallback
    }

    func start(surface: ghostty_surface_t) throws {
        startCount += 1
        observedSetSizeCountAtStart = setSizeCountSource()
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

    func surfaceWasFreed() {
        releaseCount += 1
    }
}

func fakeApp() -> ghostty_app_t {
    UnsafeMutableRawPointer(bitPattern: 0x1000)!
}

func fakeSurface() -> ghostty_surface_t {
    UnsafeMutableRawPointer(bitPattern: 0x2000)!
}

func testSurfaceHandleSpawnConfiguration() -> ZmxSpawnConfiguration {
    ZmxSpawnConfiguration.make(
        launcher: ZmxLauncher(
            executable: URL(fileURLWithPath: "/tmp/zmx"),
            zmxDir: URL(fileURLWithPath: "/tmp/zmx-dir", isDirectory: true)
        ),
        paneSessionID: PaneSessionID(id: UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000000")!),
        worktreePath: "/tmp/worktree",
        socketPath: "/tmp/graftty.sock",
        processEnv: ["SHELL": "/bin/zsh", "PATH": "/usr/bin"],
        bundleURL: URL(fileURLWithPath: "/Applications/Graftty.app"),
        ghosttyResourcesDir: nil,
        agentHooksDisabled: true,
        agentHooksRoot: URL(fileURLWithPath: "/tmp/hooks", isDirectory: true)
    )
}
