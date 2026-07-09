#if canImport(UIKit)
import Foundation
import GrafttyProtocol

@MainActor
private final class GhosttyKeybindingsCache {
    static let shared = GhosttyKeybindingsCache()
    private var byBaseURL: [URL: GhosttyKeybindBridge] = [:]
    private var generations: [URL: Int] = [:]
    private var inflight: [URL: (generation: Int, task: Task<GhosttyKeybindBridge?, Never>)] = [:]

    func bridge(for baseURL: URL) async -> GhosttyKeybindBridge {
        if let cached = byBaseURL[baseURL] { return cached }
        if let existing = inflight[baseURL] {
            return await existing.task.value ?? GhosttyDefaultKeybinds.bridge
        }
        let generation = generations[baseURL, default: 0]
        let task = Task<GhosttyKeybindBridge?, Never> { [baseURL] in
            await GhosttyKeybindingsFetcher.fetchDecodedUncached(baseURL: baseURL)
        }
        inflight[baseURL] = (generation: generation, task: task)
        let result = await task.value
        if let current = inflight[baseURL],
           current.generation == generation {
            inflight[baseURL] = nil
            if !task.isCancelled, let result {
                byBaseURL[baseURL] = result
            }
        }
        return result ?? GhosttyDefaultKeybinds.bridge
    }

    func invalidate(baseURL: URL) {
        generations[baseURL, default: 0] += 1
        byBaseURL.removeValue(forKey: baseURL)
        inflight.removeValue(forKey: baseURL)?.task.cancel()
    }
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

    /// If the fetch fails (missing endpoint on older hosts, non-2xx status,
    /// a transport failure, or an undecodable body), falls back to the
    /// bundled Ghostty default keybindings so shortcuts keep working
    /// (IPAD-9.7).
    static func fetchUncached(
        baseURL: URL,
        session: URLSession = .shared
    ) async -> GhosttyKeybindBridge {
        await fetchDecodedUncached(baseURL: baseURL, session: session)
            ?? GhosttyDefaultKeybinds.bridge
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
        return GhosttyKeybindBridge(chords: known)
    }
}
#endif
