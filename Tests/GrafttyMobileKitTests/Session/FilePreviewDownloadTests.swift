import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("@spec IOS-12.2: When a user opens an offered host file on mobile, the application shall download its bounded snapshot to a temporary local file and reject invalid names and incomplete transfers.")
struct FilePreviewDownloadTests {
    @Test func downloadsWithoutChangingBytesOrExtension() async throws {
        let bytes = Data("<html><body>Hello</body></html>".utf8)
        let offer = RemoteOpenOffer(id: UUID(), filename: "report.html", byteCount: bytes.count)
        let file = try await FilePreviewDownload.download(offer) { offset in
            bytes.subdata(in: offset..<min(offset + 5, bytes.count))
        }
        defer { FilePreviewDownload.remove(file) }
        #expect(file.lastPathComponent == "report.html")
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func preservesValidMacBackslashFilename() async throws {
        let offer = RemoteOpenOffer(id: UUID(), filename: "report\\2026.csv", byteCount: 1)
        let file = try await FilePreviewDownload.download(offer) { _ in Data([65]) }
        defer { FilePreviewDownload.remove(file) }
        #expect(file.lastPathComponent == offer.filename)
    }

    @Test(arguments: ["../secret", "/tmp/file", "..", "", "x/y"])
    func rejectsUnsafeNames(name: String) async {
        await #expect(throws: (any Error).self) {
            try await FilePreviewDownload.download(.init(id: UUID(), filename: name, byteCount: 1)) { _ in
                Issue.record("Invalid metadata must not request file data")
                return Data([1])
            }
        }
    }

    @Test func rejectsTruncatedTransfers() async {
        await #expect(throws: (any Error).self) {
            try await FilePreviewDownload.download(.init(id: UUID(), filename: "a.csv", byteCount: 2)) { _ in Data() }
        }
    }
}
