import Foundation
import GrafttyProtocol
import Observation

/// Downloaded snapshots outlive the host's temporary delivery offers.
@MainActor @Observable
final class RemotePreviewHistory {
    static let maximumCollections = 8
    static let maximumBytes = 50 * 1024 * 1024

    /// An open Quick Look presentation also owns its entry, so eviction cannot
    /// remove snapshots that the user is still viewing or sharing.
    final class Entry {
        let offer: RemoteOpenOffer
        let scope: TerminalBrowserRequest.Scope
        let files: [URL]
        let byteCount: Int

        init(offer: RemoteOpenOffer, scope: TerminalBrowserRequest.Scope, files: [URL], byteCount: Int) {
            self.offer = offer
            self.scope = scope
            self.files = files
            self.byteCount = byteCount
        }

        deinit { files.forEach(FilePreviewDownload.remove) }
    }

    private var entries: [Entry] = []

    func latest(in scope: TerminalBrowserRequest.Scope) -> Entry? {
        entries.first { $0.scope == scope }
    }

    @discardableResult
    func record(offer: RemoteOpenOffer, scope: TerminalBrowserRequest.Scope, files: [URL], byteCount: Int) -> Entry {
        let entry = Entry(offer: offer, scope: scope, files: files, byteCount: byteCount)
        entries.removeAll { $0.scope == scope }
        entries.insert(entry, at: 0)
        while entries.count > Self.maximumCollections || entries.reduce(0, { $0 + $1.byteCount }) > Self.maximumBytes {
            entries.removeLast()
        }
        return entry
    }

    func remove(hostID: UUID) {
        entries.removeAll { $0.scope.hostID == hostID }
    }
}
