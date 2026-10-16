import AppKit
import GrafttyKit
import SwiftUI
import Testing
import XCTest
@testable import Graftty

private enum PreviewLifecycleScenario: String, CaseIterable {
    case neverAttached, immediateRemoval, windowClosed, replacement, repeatedRemoval, swiftUIRemoval, swiftUIWindowClosed
}

@Suite(.serialized)
struct FilePreviewLifecycleTests {
    @Test("@spec PREVIEW-1.5: When a native macOS preview is dismantled before attachment, after window closure, or more than once, the application shall close Quick Look safely, reject subsequent preview updates, and retain its snapshots until native teardown completes.",
          arguments: PreviewLifecycleScenario.allCases)
    fileprivate func nativeTeardownSurvives(scenario: PreviewLifecycleScenario) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("child.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "GrafttyTests.FilePreviewLifecycleChild/testNativeScenario",
                           Bundle(for: FilePreviewLifecycleChild.self).bundleURL.path]
        var environment = ProcessInfo.processInfo.environment
        environment["GRAFTTY_PREVIEW_LIFECYCLE_SCENARIO"] = scenario.rawValue
        environment["GRAFTTY_PREVIEW_LIFECYCLE_RESULT"] = directory.appendingPathComponent("completed").path
        child.environment = environment
        child.standardOutput = output
        child.standardError = output
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL) } }
        let deadline = ContinuousClock.now + .seconds(20)
        while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if child.isRunning {
            // Only this test's isolated child is terminated on timeout.
            child.terminate()
            try await Task.sleep(for: .milliseconds(200))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        // waitUntilExit can stall on an exited child in the Swift Testing runner.
        let exitDeadline = ContinuousClock.now + .seconds(3)
        while child.isRunning, ContinuousClock.now < exitDeadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(!child.isRunning, "The isolated native probe did not terminate")
        let diagnostics = (try String(contentsOf: log, encoding: .utf8)).split(separator: "\n")
            .filter { $0.contains("[QL]") || $0.contains("error:") || $0.hasPrefix("Test Case") }
            .joined(separator: "\n")
        #expect(child.terminationReason == .exit && child.terminationStatus == 0,
                "Native lifecycle \(scenario.rawValue), status \(child.terminationStatus): \(diagnostics)")
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("completed").path),
                "The isolated native lifecycle must actually finish")
    }
}

/// Invoked only in an isolated xctest process, never in the shared runner.
@MainActor
final class FilePreviewLifecycleChild: XCTestCase {
    func testNativeScenario() async throws {
        guard let name = ProcessInfo.processInfo.environment["GRAFTTY_PREVIEW_LIFECYCLE_SCENARIO"],
              let scenario = PreviewLifecycleScenario(rawValue: name),
              let result = ProcessInfo.processInfo.environment["GRAFTTY_PREVIEW_LIFECYCLE_RESULT"] else {
            throw XCTSkip("Isolated native lifecycle entrypoint")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.finishLaunching()
        var files: [FilePreviewFile]? = try ["one.html", "two.txt"].map {
            try FilePreviewFile(.init(filename: $0, bytes: Data("<h1>Preview lifecycle</h1>".utf8)))
        }
        let urls = try XCTUnwrap(files?.map(\.url))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 600, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if scenario == .swiftUIWindowClosed || scenario == .swiftUIRemoval {
            var hosting: NSHostingView<AnyView>? = NSHostingView(rootView: AnyView(FilePreviewTray(
                preview: .init(files: try XCTUnwrap(files)), onDismiss: {}, onInteraction: { _ in })))
            files = nil
            window.contentView = hosting
            window.orderFront(nil)
            hosting?.layoutSubtreeIfNeeded()
            weak var native: NativeFilePreviewTray?
            native = findTray(in: try XCTUnwrap(hosting))
            XCTAssertNotNil(native, "SwiftUI must mount the actual Quick Look tray")
            if scenario == .swiftUIWindowClosed { window.close() }
            XCTAssertTrue(urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            hosting?.rootView = AnyView(EmptyView())
            hosting?.layoutSubtreeIfNeeded()
            window.contentView = nil
            hosting = nil
            try await waitForRelease(urls)
            XCTAssertNil(native, "SwiftUI must release the dismantled native tray")
            try Data("completed".utf8).write(to: URL(fileURLWithPath: result))
            return
        }
        var tray: NativeFilePreviewTray? = NativeFilePreviewTray(
            preview: .init(files: try XCTUnwrap(files)), onDismiss: {}, onInteraction: { _ in })
        files = nil
        if scenario != .neverAttached {
            window.contentView = tray
            window.orderFront(nil)
            if scenario != .immediateRemoval { try await Task.sleep(for: .milliseconds(250)) }
            if scenario == .replacement {
                let replacement = try FilePreviewFile(.init(filename: "replacement.html", bytes: Data("replacement".utf8)))
                tray?.update(.init(files: [replacement]))
                try await Task.sleep(for: .milliseconds(250))
            }
            if scenario == .windowClosed || scenario == .replacement {
                window.close()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let currentURL = try XCTUnwrap(tray?.previewURL)
        try autoreleasepool {
            let mounted = try XCTUnwrap(tray)
            XCTAssertFalse(mounted.quickLook.shouldCloseWithWindow)
            XCTAssertEqual(mounted.quickLook.previewItem?.previewItemURL, currentURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path))
            FilePreviewTray.dismantleNSView(mounted, coordinator: ())
            if scenario == .repeatedRemoval || scenario == .neverAttached {
                FilePreviewTray.dismantleNSView(mounted, coordinator: ())
            }
            XCTAssertNil(mounted.quickLook.previewItem)
            XCTAssertTrue(FileManager.default.fileExists(atPath: currentURL.path), "The tray still owns its snapshot")
            let selectedIndex = mounted.selectedIndex
            mounted.nextFile()
            mounted.previousFile()
            let ignored = try FilePreviewFile(.init(filename: "ignored.txt", bytes: Data("ignored".utf8)))
            mounted.update(.init(files: [ignored]))
            XCTAssertNil(mounted.quickLook.previewItem)
            XCTAssertEqual(mounted.selectedIndex, selectedIndex)
            window.orderOut(nil)
            window.contentView = nil
            tray = nil
        }
        try await waitForRelease(urls + [currentURL])
        try Data("completed".utf8).write(to: URL(fileURLWithPath: result))
    }

    private func findTray(in view: NSView) -> NativeFilePreviewTray? {
        if let tray = view as? NativeFilePreviewTray { return tray }
        return view.subviews.lazy.compactMap { self.findTray(in: $0) }.first
    }

    private func waitForRelease(_ urls: [URL]) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while urls.contains(where: { FileManager.default.fileExists(atPath: $0.path) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Snapshots must leave with their final owner")
    }
}
