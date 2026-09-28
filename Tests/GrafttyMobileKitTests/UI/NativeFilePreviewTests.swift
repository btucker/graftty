#if canImport(UIKit)
import Foundation
import QuickLook
import Testing
import UIKit
@testable import GrafttyMobileKit

@MainActor
@Suite("@spec IOS-12.7: When an offered file has a native Quick Look preview, the application shall show it with Quick Look; otherwise, it shall present the system sharing and Open In interface.")
struct NativeFilePreviewTests {
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
