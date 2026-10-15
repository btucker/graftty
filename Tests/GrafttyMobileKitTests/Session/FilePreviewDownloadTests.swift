import Foundation
import Testing
import GrafttyProtocol
@testable import GrafttyMobileKit

@Suite("@spec IOS-12.2: When a user opens an offered host file on mobile, the application shall download its bounded snapshot to a temporary local file and reject invalid names and incomplete transfers.")
struct FilePreviewDownloadTests {
    @Test("@spec PREVIEW-2.6: If any file in a preview collection fails to download, then mobile shall remove previously downloaded files from that collection and present no partial collection.")
    func collectionFailureRemovesEarlierFiles() async throws {
        let name = UUID().uuidString + ".html"
        let offers = [RemoteOpenOffer(id: UUID(), filename: name, byteCount: 1),
                      RemoteOpenOffer(id: UUID(), filename: "fail.csv", byteCount: 1)]
        var downloaded: URL?
        await #expect(throws: (any Error).self) {
            try await FilePreviewDownload.download(offers) { offer, _ in
                if offer == offers[0] { return Data([1]) }
                downloaded = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                    includingPropertiesForKeys: nil).map { $0.appendingPathComponent(name) }.first {
                        FileManager.default.fileExists(atPath: $0.path)
                    }
                throw FilePreviewDownload.Failure.invalidChunk
            }
        }
        let file = try #require(downloaded)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test("@spec IMAGE-2.9: If an image transfer fails or is cancelled after receiving bytes, then the application shall remove its temporary download directory; when its preview closes, the application shall remove the completed local file.")
    func failedAndCancelledImageTransfersRemoveTemporaryBytes() async throws {
        for cancelled in [false, true] {
            let name = UUID().uuidString + ".png"
            let offer = RemoteOpenOffer(id: UUID(), filename: name, byteCount: 1)
            var directory: URL?
            let task = Task {
                try await FilePreviewDownload.download(offer) { _ in
                    directory = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory,
                        includingPropertiesForKeys: nil).first {
                            FileManager.default.fileExists(atPath: $0.appendingPathComponent(name).path)
                        }
                    if cancelled { withUnsafeCurrentTask { $0?.cancel() }; return Data([1]) }
                    throw FilePreviewDownload.Failure.invalidChunk
                }
            }
            await #expect(throws: (any Error).self) { try await task.value }
            let created = try #require(directory)
            #expect(!FileManager.default.fileExists(atPath: created.path))
        }
        let file = try await FilePreviewDownload.download(.init(id: UUID(), filename: "complete.png", byteCount: 1)) { _ in Data([1]) }
        #expect(FileManager.default.fileExists(atPath: file.path))
        FilePreviewDownload.remove(file)
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
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
