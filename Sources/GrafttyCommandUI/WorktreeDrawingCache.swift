import Foundation
import ImageIO
import Observation

/// @spec IOS-4.65
/// Rendered worktree drawings a client fetched from its host, keyed by
/// revision. A revision names one image forever, so nothing is refetched.
@Observable @MainActor
public final class WorktreeDrawingCache {
    public static let maxBytes = 262_144
    public private(set) var images: [String: Data] = [:]
    private var loading = Set<String>()
    private var generation = 0

    public init() {}

    public func load(revision: String, fetch: () async -> Data?) async {
        guard images[revision] == nil, loading.insert(revision).inserted else { return }
        let started = generation
        defer { if generation == started { loading.remove(revision) } }
        guard let data = await fetch(), generation == started, data.count <= Self.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return }
        images[revision] = data
    }

    /// Another host may reuse revisions' worktree paths, so its drawings start empty.
    public func reset() {
        images = [:]
        loading = []
        generation += 1
    }
}
