import Foundation
import Observation
import GrafttyProtocol

/// A local page opens only after an explicit mode selection in its originating scope.
@MainActor @Observable
final class LocalBrowserSession {
    private(set) var url: URL?
    private(set) var preparing = false
    private(set) var error: String?
    private var generation: UUID?
    private let release: () -> Void

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    init(release: @escaping () -> Void = {}) { self.release = release }

    func open(originalURL: URL, isAllowed: () -> Bool,
              authorize: () async throws -> URL,
              prepare: (URL) async throws -> Void) async {
        guard !preparing, url == nil else { return }
        stop()
        let generation = UUID()
        self.generation = generation
        preparing = true
        defer { if self.generation == generation { preparing = false } }
        do {
            try checkCurrent(generation, isAllowed: isAllowed)
            let approved = try await authorize()
            try checkCurrent(generation, isAllowed: isAllowed)
            guard approved == originalURL else { throw Failure(message: "The host changed the original browser URL.") }
            try await prepare(approved)
            try checkCurrent(generation, isAllowed: isAllowed)
            url = approved
        } catch {
            guard self.generation == generation else { return }
            // Do not expose untrusted callback URLs or OAuth parameters in errors.
            stop(reason: (error as? Failure)?.message ?? "Local browser unavailable. Reconnect with pane control and try again.")
        }
    }

    func stop(reason: String? = nil) {
        generation = nil
        url = nil
        preparing = false
        error = reason
        release()
    }

    private func checkCurrent(_ generation: UUID, isAllowed: () -> Bool) throws {
        try Task.checkCancellation()
        guard self.generation == generation, isAllowed() else { throw CancellationError() }
    }
}

/// OAuth uses the retained offer. Ordinary browsing follows the selected remote page.
enum LocalBrowserSelection {
    static func url(originalOffer: URL?, selectedPage: URL?) throws -> URL {
        if let originalOffer, ChromeTabAction.launch(url: originalOffer.absoluteString).isValid,
           WorktreeAuthenticationURL(url: originalOffer) != nil,
           !WorktreeAuthenticationURL.isLoopbackHost(originalOffer.host ?? "") { return originalOffer }
        guard let url = selectedPage,
              ChromeTabAction.launch(url: url.absoluteString).isValid else {
            throw LocalBrowserSession.Failure(message: "Select an HTTP or HTTPS page before opening Local mode.")
        }
        guard WorktreeAuthenticationURL(url: url) == nil else {
            throw LocalBrowserSession.Failure(message: "Open the original sign-in offer before selecting Local mode.")
        }
        return url
    }
}
