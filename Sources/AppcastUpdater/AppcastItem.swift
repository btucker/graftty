import Foundation

/// One release entry for the Sparkle appcast feed.
///
/// `version` is the canonical short version string (e.g. "0.2.3"). We do
/// not distinguish `sparkle:version` from `sparkle:shortVersionString` —
/// Graftty ships a single versioning series, and the appcast writer emits
/// both elements with the same value.
public struct AppcastItem: Equatable, Sendable {
    public let version: String
    public let pubDate: Date
    public let minimumSystemVersion: String
    public let releaseNotesMarkdown: String
    public let downloadURL: String
    public let contentLength: Int
    public let edSignature: String

    public init(
        version: String,
        pubDate: Date,
        minimumSystemVersion: String,
        releaseNotesMarkdown: String,
        downloadURL: String,
        contentLength: Int,
        edSignature: String
    ) {
        self.version = version
        self.pubDate = pubDate
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesMarkdown = releaseNotesMarkdown
        self.downloadURL = downloadURL
        self.contentLength = contentLength
        self.edSignature = edSignature
    }
}
