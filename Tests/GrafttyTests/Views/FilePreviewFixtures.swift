import AppKit
import GrafttyKit
import Testing
@testable import Graftty

extension ImagePreviewStore.Preview {
    init(image: CGImage, filename: String, sourceURL: URL? = nil) throws {
        let bytes = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        self.init(files: [try FilePreviewFile(.init(filename: filename, bytes: bytes), sourceURL: sourceURL)])
    }
}

extension ImagePreviewStore {
    func present(_ image: CGImage, filename: String, sourceURL: URL? = nil, for pane: PaneSlotID) throws {
        let preview = try Preview(image: image, filename: filename, sourceURL: sourceURL)
        present(files: preview.files, for: pane)
    }
}
