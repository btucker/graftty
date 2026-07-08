#if canImport(UIKit)
import Foundation
import GrafttyProtocol

@MainActor
private final class GhosttyKeybindingsCache {
    static let shared = GhosttyKeybindingsCache()
    private var byBaseURL: [URL: GhosttyKeybindBridge] = [:]
    private var inflight: [URL: Task<GhosttyKeybindBridge?, Never>] = [:]

    func bridge(for baseURL: URL) async -> GhosttyKeybindBridge {
        if let cached = byBaseURL[baseURL] { return cached }
        if let existing = inflight[baseURL] {
            return await existing.value ?? emptyGhosttyKeybindBridge()
        }
        let task = Task<GhosttyKeybindBridge?, Never> { [baseURL] in
            await GhosttyKeybindingsFetcher.fetchDecodedUncached(baseURL: baseURL)
        }
        inflight[baseURL] = task
        let result = await task.value
        inflight[baseURL] = nil
        if let result { byBaseURL[baseURL] = result }
        return result ?? emptyGhosttyKeybindBridge()
    }

    func invalidate(baseURL: URL) {
        byBaseURL.removeValue(forKey: baseURL)
    }
}

private func emptyGhosttyKeybindBridge() -> GhosttyKeybindBridge {
    GhosttyKeybindBridge { _ in nil }
}

/// Pulls the Mac server's resolved Ghostty keybindings from
/// `GET <baseURL>/ghostty-keybindings` so iPad can mirror host command
/// shortcuts after the focused command context is wired.
public enum GhosttyKeybindingsFetcher {
    @MainActor
    public static func fetch(baseURL: URL) async -> GhosttyKeybindBridge {
        await GhosttyKeybindingsCache.shared.bridge(for: baseURL)
    }

    @MainActor
    public static func invalidateCache(for baseURL: URL) {
        GhosttyKeybindingsCache.shared.invalidate(baseURL: baseURL)
    }

    static func fetchUncached(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> GhosttyKeybindBridge {
        await fetchDecodedUncached(baseURL: baseURL, session: session)
            ?? emptyGhosttyKeybindBridge()
    }

    static func fetchDecodedUncached(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> GhosttyKeybindBridge? {
        guard let url = baseURL.appendingAPIPath("ghostty-keybindings") else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let decoded = try JSONDecoder().decode(GhosttyKeybindingsResponse.self, from: data)
            return bridge(from: decoded)
        } catch {
            return nil
        }
    }

    static func bridge(from response: GhosttyKeybindingsResponse) -> GhosttyKeybindBridge {
        var known: [GhosttyAction: ShortcutChord] = [:]
        for (rawAction, chord) in response.bindings {
            guard let action = GhosttyAction(rawValue: rawAction) else { continue }
            known[action] = chord
        }
        return GhosttyKeybindBridge { rawAction in
            guard let action = GhosttyAction(rawValue: rawAction) else { return nil }
            return known[action]
        }
    }
}
#endif
