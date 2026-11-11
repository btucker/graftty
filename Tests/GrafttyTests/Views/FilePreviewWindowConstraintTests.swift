import AppKit
import GrafttyKit
import SwiftUI
import Testing
import XCTest
@testable import Graftty

struct FilePreviewWindowConstraintTests {
    @Test("@spec PREVIEW-1.22: When a macOS preview window is resized, hidden, or updated, the application shall preserve its requested size without repeated titlebar-height growth or constraint exceptions.")
    func previewSizingConverges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("preview-constraints-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = directory.appendingPathComponent("child.log")
        let result = directory.appendingPathComponent("completed")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "GrafttyTests.FilePreviewWindowConstraintChild/testWindowLifecycle",
                           Bundle(for: FilePreviewWindowConstraintChild.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_PREVIEW_CONSTRAINT_RESULT"] = result.path
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(20)
        while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            Issue.record("Preview sizing exceeded its 20-second deadline; log: \(log.path)")
            return
        }
        let completed = FileManager.default.fileExists(atPath: result.path)
        let succeeded = child.terminationReason == .exit && child.terminationStatus == 0 && completed
        #expect(succeeded, "Preview sizing child exited with \(child.terminationStatus), completed=\(completed); log: \(log.path)")
        if succeeded { try? FileManager.default.removeItem(at: directory) }
    }
}

/// Run AppKit's application display cycle in an isolated process. Merely pumping
/// XCTest's run loop did not reproduce the window's animated sizing feedback.
@MainActor
final class FilePreviewWindowConstraintChild: XCTestCase {
    func testWindowLifecycle() throws {
        guard let result = ProcessInfo.processInfo.environment["GRAFTTY_PREVIEW_CONSTRAINT_RESULT"] else {
            throw XCTSkip("Isolated preview constraint entrypoint")
        }
        PreviewConstraintApp.exercise = { [self] in
            do {
                try await exerciseWindows()
                guard testRun?.failureCount == 0 else { exit(1) }
                try Data("completed".utf8).write(to: URL(fileURLWithPath: result))
                exit(0)
            } catch {
                fputs("Preview constraint probe failed: \(error)\n", stderr)
                exit(1)
            }
        }
        // XCTest does not deliver the launch event that normally opens the
        // first WindowGroup window. Use the public delegate entrypoint.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                _ = NSApp.setActivationPolicy(.accessory)
                _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
            }
        }
        PreviewConstraintApp.main()
    }

    private func exerciseWindows() async throws {
        let main = try XCTUnwrap(NSApp.windows.first { $0.contentView != nil })
        let history = FilePreviewHistory()
        let windows = FilePreviewWindows(history: history, inline: ImagePreviewStore())
        defer { windows.closeAll(); main.orderOut(nil) }
        let pane = PaneSlotID()
        let worktree = FileManager.default.temporaryDirectory.appendingPathComponent("preview-fixture-\(UUID())").path
        let sizes: [NSSize] = [.init(width: 900, height: 650), .init(width: 900.5, height: 1600),
                               .init(width: 480, height: 320), .init(width: 1200, height: 450.5)]
        for index in 0..<8 {
            let body = String(repeating: "<p>Synthetic preview content that wraps when the window is resized.</p>", count: index.isMultiple(of: 2) ? 2 : 100)
            let file = try FilePreviewFile(.init(filename: "preview-\(index).html", bytes: Data(("<!doctype html><meta charset=utf-8>" + body).utf8)))
            let entry = history.record(files: [file], pane: pane, worktreePath: worktree)
            windows.show(entry, activate: false, catalogRequest: { _ in .offers([]) })
            let window = try XCTUnwrap(windows.window(for: worktree))
            let size = sizes[index % sizes.count]
            window.setFrame(NSRect(origin: .init(x: 100, y: 100), size: size), display: true)
            let acceptedSize = window.frame.size
            if index.isMultiple(of: 2) { window.orderOut(nil) }
            main.setContentSize(.init(width: 700 + index * 30, height: 400 + index * 20))
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(window.frame.width, acceptedSize.width, accuracy: 1)
            XCTAssertEqual(window.frame.height, acceptedSize.height, accuracy: 1,
                           "Content layout must not repeatedly add the titlebar height")
            let content = try XCTUnwrap(window.contentView)
            let tray = try XCTUnwrap(findTray(in: content))
            let frame = tray.convert(tray.bounds, to: content)
            XCTAssertEqual(frame.minY, 0, accuracy: 1, "Preview chrome must still extend under the titlebar")
            XCTAssertEqual(frame.height, content.bounds.height, accuracy: 1)
            if index % 3 == 2 { window.performClose(nil) }
        }
    }

    private func findTray(in view: NSView) -> NativeFilePreviewTray? {
        if let tray = view as? NativeFilePreviewTray { return tray }
        return view.subviews.lazy.compactMap { self.findTray(in: $0) }.first
    }
}

@MainActor
private struct PreviewConstraintApp: App {
    static var exercise: (() async -> Void)?
    var body: some Scene {
        WindowGroup {
            Color.gray.frame(minWidth: 500, minHeight: 300)
                .task {
                    let action = Self.exercise
                    Self.exercise = nil
                    await action?()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 750)
    }
}
