#if canImport(UIKit)
import Foundation
import GrafttyProtocol

public enum MobileGhosttyKeybindingSource: Sendable, Equatable {
    case loading
    case hostResolved
    case bundledFallback
}

public struct MobileGhosttyKeybindingSet: Sendable {
    public let bridge: GhosttyKeybindBridge
    public let source: MobileGhosttyKeybindingSource

    static let loading = MobileGhosttyKeybindingSet(
        bridge: .empty,
        source: .loading
    )

    static let bundledFallback = MobileGhosttyKeybindingSet(
        bridge: GhosttyDefaultKeybinds.bridge,
        source: .bundledFallback
    )
}

@MainActor
private final class GhosttyKeybindingsCache {
    static let shared = GhosttyKeybindingsCache()
    private var byBaseURL: [URL: MobileGhosttyKeybindingSet] = [:]
    private var generations: [URL: Int] = [:]
    private var inflight: [URL: (generation: Int, task: Task<MobileGhosttyKeybindingSet, Never>)] = [:]

    func keybindingSet(for baseURL: URL) async -> MobileGhosttyKeybindingSet {
        if let cached = byBaseURL[baseURL] { return cached }
        if let existing = inflight[baseURL] {
            return await existing.task.value
        }
        let generation = generations[baseURL, default: 0]
        let task = Task<MobileGhosttyKeybindingSet, Never> { [baseURL] in
            await GhosttyKeybindingsFetcher.fetchUncached(baseURL: baseURL)
        }
        inflight[baseURL] = (generation: generation, task: task)
        let result = await task.value
        if let current = inflight[baseURL],
           current.generation == generation {
            inflight[baseURL] = nil
            if !task.isCancelled, result.source == .hostResolved {
                byBaseURL[baseURL] = result
            }
        }
        return result
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
    public static func fetch(baseURL: URL) async -> MobileGhosttyKeybindingSet {
        await GhosttyKeybindingsCache.shared.keybindingSet(for: baseURL)
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
    ) async -> MobileGhosttyKeybindingSet {
        guard let url = baseURL.appendingAPIPath("ghostty-keybindings") else {
            return .bundledFallback
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .bundledFallback
            }
            let decoded = try JSONDecoder().decode(GhosttyKeybindingsResponse.self, from: data)
            return MobileGhosttyKeybindingSet(
                bridge: bridge(from: decoded),
                source: .hostResolved
            )
        } catch {
            return .bundledFallback
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
