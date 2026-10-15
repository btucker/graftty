import AppKit
import GrafttyKit
import QuickLookUI
import Testing
@testable import Graftty

@MainActor
struct FilePreviewCollectionTests {
    @Test("@spec IMAGE-1.14: While the native preview tray toolbar is visible, the application shall keep collection navigation, file selection, Open… and Close controls legible and reachable in both wide and narrow panes.")
    func toolbarControlsFitNarrowAndWidePanes() throws {
        _ = NSApplication.shared
        let file = try FilePreviewFile(.init(filename: "long filename.html", bytes: Data()))
        let tray = NativeFilePreviewTray(preview: .init(files: [file]), onDismiss: {}, onInteraction: { _ in })
        for width in [180.0, 240, 320, 800] {
            tray.frame = NSRect(x: 0, y: 0, width: width, height: 240)
            tray.layoutSubtreeIfNeeded()
            for control in [tray.previous, tray.next, tray.picker, tray.open, tray.close] {
                #expect(control.frame.minX >= 0 && control.frame.maxX <= width)
                #expect(control.frame.minY >= 0 && control.frame.maxY <= tray.header.bounds.height)
            }
            #expect(tray.open.frame.width >= tray.open.intrinsicContentSize.width)
            #expect(!tray.picker.frame.intersects(tray.open.frame))
            #expect(!tray.picker.frame.intersects(tray.close.frame))
        }
    }

    @Test("@spec IMAGE-1.15: When the user selects Open… from a native preview tray, the application shall open the selected original file in its default application and display launch errors without dismissing the collection.")
    func opensOriginalAndReportsLaunchErrors() async throws {
        let original = URL(fileURLWithPath: "/tmp/original-report.html")
        let file = try FilePreviewFile(.init(filename: "report.html", bytes: Data()), sourceURL: original)
        var opened: [URL] = []
        var shouldFail = true
        var dismissed = false
        let tray = NativeFilePreviewTray(preview: .init(files: [file]), onDismiss: { dismissed = true }, onInteraction: { _ in }, openFile: {
            opened.append($0)
            if shouldFail { throw CocoaError(.fileReadNoSuchFile) }
        })
        await tray.openInDefaultApp()
        #expect(opened == [original])
        #expect(tray.openErrorMessage != nil)
        #expect(!dismissed)
        shouldFail = false
        await tray.openInDefaultApp()
        #expect(tray.openErrorMessage == nil)
        await #expect(throws: FilePreviewExternalOpen.Failure.unavailable) {
            try await FilePreviewExternalOpen.open(URL(fileURLWithPath: "/tmp/" + UUID().uuidString))
        }
    }

    @Test("@spec PREVIEW-1.3: When a native file preview collection opens on macOS, the application shall embed Quick Look, navigate files in request order, reset selection on replacement, and retain immutable snapshot files until the tray releases them.")
    func navigatesCollectionAndRetainsSnapshots() throws {
        _ = NSApplication.shared
        let files = try ["one.html", "two.csv"].map {
            try FilePreviewFile(.init(filename: $0, bytes: Data("<h1>Preview</h1>".utf8)))
        }
        let urls = files.map(\.url)
        let tray = NativeFilePreviewTray(preview: .init(files: files), onDismiss: {}, onInteraction: { _ in })
        #expect(tray.quickLook.previewItem?.previewItemURL == urls[0])
        #expect(!tray.previous.isEnabled && tray.next.isEnabled)
        tray.nextFile()
        #expect(tray.selectedIndex == 1)
        #expect(tray.quickLook.previewItem?.previewItemURL == urls[1])
        #expect(tray.previous.isEnabled && !tray.next.isEnabled)
        tray.nextFile()
        #expect(tray.selectedIndex == 1)
        tray.previousFile()
        #expect(tray.selectedIndex == 0)
        let replacement = try FilePreviewFile(.init(filename: "new.txt", bytes: Data("new".utf8)))
        tray.update(.init(files: [replacement]))
        #expect(tray.selectedIndex == 0)
        #expect(tray.quickLook.previewItem?.previewItemURL == replacement.url)
        #expect(!tray.next.isEnabled)
    }

    @Test("@spec PREVIEW-1.4: When a preview file snapshot is released, the application shall remove its private temporary directory without deleting the original file.")
    func removesOnlySnapshotWhenReleased() throws {
        var file: FilePreviewFile? = try FilePreviewFile(.init(filename: "chart.html", bytes: Data("hello".utf8)))
        let url = try #require(file?.url)
        #expect(try Data(contentsOf: url) == Data("hello".utf8))
        file = nil
        #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
    }
}
