import Foundation

/// One release entry for the Sparkle appcast feed.
///
/// @spec UPDATE-3.2: When the release workflow publishes any update, the application shall write its monotonically increasing build version to `sparkle:version` and its human-readable tag version to `sparkle:shortVersionString`.
///
/// `buildVersion` is the monotonically increasing, machine-readable version
/// Sparkle compares. `displayVersion` is the release name shown to the user,
/// such as `0.6.0-beta.1`. Keeping them separate lets a stable release sort
/// after every prerelease for that release without exposing an internal build
/// number in the update UI.
public struct AppcastItem: Equatable, Sendable {
    public let buildVersion: String
    public let displayVersion: String
    public let channel: String?
    public let pubDate: Date
    public let minimumSystemVersion: String
    public let releaseNotesMarkdown: String
    public let downloadURL: String
    public let contentLength: Int
    public let edSignature: String

    public init(
        buildVersion: String,
        displayVersion: String,
        channel: String?,
        pubDate: Date,
        minimumSystemVersion: String,
        releaseNotesMarkdown: String,
        downloadURL: String,
        contentLength: Int,
        edSignature: String
    ) {
        self.buildVersion = buildVersion
        self.displayVersion = displayVersion
        self.channel = channel
        self.pubDate = pubDate
        self.minimumSystemVersion = minimumSystemVersion
        self.releaseNotesMarkdown = releaseNotesMarkdown
        self.downloadURL = downloadURL
        self.contentLength = contentLength
        self.edSignature = edSignature
    }
}
