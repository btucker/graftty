#if canImport(UIKit)
import Foundation
import QuickLook
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IOS-12.7: When an offered file has a native Quick Look preview, the application shall show it with Quick Look; otherwise, it shall present the system sharing and Open In interface.")
struct NativeFilePreviewTests {
    @Test("@spec IMAGE-2.8: When a mobile image opens, the application shall use a native Quick Look controller in a navigation container with a Done action and the system image zoom and sharing interface.")
    func imageUsesQuickLookWithNativeNavigationAndDone() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let bytes = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(QLPreviewController.canPreview(url as NSURL))
        var dismissed = false
        let source = NativeImagePreview.Coordinator(url: url, dismiss: { dismissed = true })
        let navigation = NativeImagePreview.makeController(coordinator: source)
        let preview = try #require(navigation.topViewController as? QLPreviewController)
        #expect(preview.dataSource === source.source)
        #expect(source.source.previewController(preview, previewItemAt: 0).previewItemURL == url)
        let done = try #require(preview.navigationItem.leftBarButtonItem)
        #expect(done.target === source)
        source.done()
        #expect(dismissed)
    }
    @Test(arguments: ["html", "csv", "txt"])
    func supportedFilesUseApplesPreview(extension suffix: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + suffix)
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = NativeFilePreview.Coordinator(url: url)
        #expect(QLPreviewController.canPreview(url as NSURL))
        let controller = NativeFilePreview.makeController(url: url, dataSource: source)
        #expect(controller is QLPreviewController)
        #expect(source.numberOfPreviewItems(in: QLPreviewController()) == 1)
        #expect(source.previewController(QLPreviewController(), previewItemAt: 0).previewItemURL == url)
    }

    @Test func unsupportedFilesUseSystemSharingFallback() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".graftty-unknown-preview")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = NativeFilePreview.Coordinator(url: url)
        #expect(!QLPreviewController.canPreview(url as NSURL))
        #expect(NativeFilePreview.makeController(url: url, dataSource: source) is UIActivityViewController)
    }
}
#endif
