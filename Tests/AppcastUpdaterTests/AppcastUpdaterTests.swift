import Testing
import Foundation
@testable import AppcastUpdater

@Suite("AppcastUpdater")
struct AppcastUpdaterTests {

    private func fixture(_ name: String) throws -> String {
        let url = Bundle.module.url(forResource: name, withExtension: "xml",
                                    subdirectory: "Fixtures")!
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let fixedDate = Date(timeIntervalSince1970: 1_713_830_400)
    // 2024-04-23 00:00:00 UTC — stable RFC822 for golden-file comparison.

    private func newItem(version: String, notes: String = "notes", signature: String = "sig")
    -> AppcastItem {
        AppcastItem(
            version: version,
            pubDate: fixedDate,
            minimumSystemVersion: "14.0",
            releaseNotesMarkdown: notes,
            downloadURL: "https://github.com/btucker/graftty/releases/download/v\(version)/Graftty-\(version).zip",
            contentLength: 1234,
            edSignature: signature
        )
    }

    @Test func seedsEmptyFeedWhenInputIsNil() throws {
        let out = try AppcastUpdater.prepend(item: newItem(version: "0.2.0"), to: nil)
        #expect(out.contains("<rss"))
        #expect(out.contains("<sparkle:version>0.2.0</sparkle:version>"))
        #expect(out.contains("<channel>"))
    }

    @Test func prependsToExistingFeed() throws {
        let existing = try fixture("one-item-feed")
        let out = try AppcastUpdater.prepend(item: newItem(version: "0.2.0"), to: existing)
        // New entry comes first.
        let idxNew = out.range(of: "<sparkle:version>0.2.0</sparkle:version>")!.lowerBound
        let idxOld = out.range(of: "<sparkle:version>0.1.0</sparkle:version>")!.lowerBound
        #expect(idxNew < idxOld)
        // Old entry preserved intact.
        #expect(out.contains("sig01"))
        #expect(out.contains("Graftty-0.1.0.zip"))
    }

    @Test func isIdempotentOnSameVersion() throws {
        let existing = try fixture("one-item-feed")
        let out = try AppcastUpdater.prepend(item: newItem(version: "0.1.0"), to: existing)
        // Exactly one `<sparkle:version>0.1.0</sparkle:version>` after the no-op.
        let occurrences = out.components(separatedBy: "<sparkle:version>0.1.0</sparkle:version>").count - 1
        #expect(occurrences == 1)
    }

    @Test func escapesReleaseNotesWithCDATA() throws {
        let notes = "Fix: handle `<tag>` & quote\"breaks"
        let out = try AppcastUpdater.prepend(
            item: newItem(version: "0.3.0", notes: notes),
            to: nil
        )
        // CDATA section must be present with the raw content — no entity encoding.
        #expect(out.contains("<![CDATA[\(notes)]]>"))
    }

    @Test func enclosureCarriesLengthAndSignature() throws {
        let out = try AppcastUpdater.prepend(
            item: newItem(version: "0.4.0", signature: "abc123=="),
            to: nil
        )
        #expect(out.contains("length=\"1234\""))
        #expect(out.contains("sparkle:edSignature=\"abc123==\""))
        #expect(out.contains("type=\"application/octet-stream\""))
    }

    @Test func minimumSystemVersionFromItem() throws {
        let item = AppcastItem(
            version: "0.5.0",
            pubDate: fixedDate,
            minimumSystemVersion: "15.0",
            releaseNotesMarkdown: "",
            downloadURL: "https://example.com/x.zip",
            contentLength: 1,
            edSignature: "s"
        )
        let out = try AppcastUpdater.prepend(item: item, to: nil)
        #expect(out.contains("<sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>"))
    }
}
