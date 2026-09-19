import AppKit
import Combine
import CryptoKit
import GrafttyKit

struct WorktreeMapGeneration: Sendable {
    let rows: [WorktreeMapRow]
    let project: ProjectArtworkSource
    let style: WorktreeArtworkStyle
    let theme: WorktreeArtworkTheme?
    let preservedPaths: Set<String>
    var preservedRegions: [String: Data] = [:]
}

/// One serial worker for project maps. Prompt text is never written to the map cache.
@MainActor
final class ProjectWorktreeMapStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var regeneratingPaths = Set<String>()
    @Published private(set) var failures: [String: String] = [:]

    private struct Slot: Codable, Equatable {
        let path: String
        let name: String
        let height: Double
        let hasLandmark: Bool
        var isConnector: Bool? = nil
        var row: WorktreeMapRow { .init(path: path, name: name, height: height, context: nil) }
    }
    private struct Saved: Codable {
        let slots: [Slot]
        let image: Data
        let landmarks: [String: Data]
        let heights: [String: Double]
        var regionIDs: [String: Int]? = nil
        var contextualPaths: Set<String>? = nil
        var regionRevision: Int? = nil
    }
    private struct Map {
        var slots: [Slot]
        var image: NSImage
        var landmarks: [String: NSImage]
        var regionIDs: [String: Int] = [:]
        var contextualPaths = Set<String>()
        var regionRevision = 0
    }
    private let directory: URL
    private let history: @MainActor (WorktreeArtworkRequest) async -> String?
    private let generate: @MainActor (WorktreeMapGeneration) async throws -> Data
    private let debounce: Duration
    private var requests: [WorktreeArtworkRequest] = []
    private var maps: [String: Map] = [:]
    private var loaded = Set<String>()
    private var contexts: [String: String] = [:]
    private var latestPrompts: [String: String] = [:]
    private var checkedHistory = Set<String>()
    private var refreshHistory = Set<String>()
    private var replaced = Set<String>()
    private var dirty = Set<String>()
    private var revisions: [String: UInt64] = [:]
    private var worker: Task<Void, Never>?
    private var generatingProject: ProjectArtworkSource?
    private var enabled = true
    private var active = false
    private var style: WorktreeArtworkStyle = .illustration
    private var theme: WorktreeArtworkTheme?

    init(directory: URL, debounce: Duration = .seconds(1.5),
         history: @escaping @MainActor (WorktreeArtworkRequest) async -> String?,
         generate: @escaping @MainActor (WorktreeMapGeneration) async throws -> Data) {
        self.directory = directory
        self.debounce = debounce
        self.history = history
        self.generate = generate
    }

    private func key(_ project: ProjectArtworkSource) -> String {
        project.cacheKey + "-" + style.rawValue + "-" + (theme?.backdropCacheKey ?? "unthemed")
    }
    private var projects: [ProjectArtworkSource] {
        var seen = Set<String>()
        return requests.compactMap(\.project).filter { seen.insert(key($0)).inserted }
    }
    private func members(_ project: ProjectArtworkSource) -> [WorktreeArtworkRequest] {
        requests.filter { $0.project == project }
    }
    private func slots(_ project: ProjectArtworkSource) -> [Slot] {
        let contextualPaths = maps[key(project)]?.contextualPaths ?? []
        return members(project).filter(\.mapVisible).map {
            Slot(path: $0.path, name: $0.name,
                 height: WorktreeMapLayout.height(max($0.mapFolder ? 44 : 80, $0.mapHeight)),
                 hasLandmark: !$0.mapFolder && (contexts[$0.path] != nil || contextualPaths.contains($0.path)),
                 isConnector: $0.mapFolder)
        }
    }

    func update(worktrees: [WorktreeArtworkRequest], isActive: Bool) {
        let previousRequests = requests
        let previous = Dictionary(requests.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        requests = worktrees.filter { $0.project != nil && seen.insert($0.path).inserted }
        active = isActive
        for request in requests where request.isMainCheckout && !request.mapFolder {
            contexts[request.path] = "The project's root landmark, inspired by its avatar and purpose."
        }
        for request in requests where previous[request.path]?.firstPaneSessionName != request.firstPaneSessionName {
            checkedHistory.remove(request.path)
        }
        regeneratingPaths.formIntersection(seen)
        images = images.filter { seen.contains($0.key) }
        for request in requests where previous[request.path]?.project?.path != request.project?.path {
            images[request.path] = nil
        }
        for project in projects {
            let sourceChanged = previousRequests.contains { $0.project?.path == project.path && $0.project != project }
            load(project, restoreDisplayedPixels: sourceChanged)
            // Compare desired inputs, not the last completed map: identical
            // updates must not invalidate an image that is still generating.
            if previousRequests.filter({ $0.project == project }) != members(project) { invalidate(project) }
        }
        // A map can take several minutes. Losing focus must not discard completed
        // regions; nextProject already pauses the queue before another project.
        if generatingProject.map({ !projects.contains($0) }) == true { worker?.cancel() }
        start()
    }

    func configure(enabled: Bool, style: WorktreeArtworkStyle) {
        guard self.enabled != enabled || self.style != style else { return }
        worker?.cancel()
        self.enabled = enabled
        if self.style != style {
            self.style = style
            images.removeAll()
            failures.removeAll()
            replaced.removeAll()
            refreshHistory.removeAll()
            regeneratingPaths.removeAll()
            for project in projects { load(project); invalidate(project) }
        }
        start()
    }

    func configure(theme: WorktreeArtworkTheme) {
        let changed = self.theme?.backdropCacheKey != theme.backdropCacheKey
        self.theme = theme
        guard changed else { return }
        worker?.cancel()
        images.removeAll()
        for project in projects { load(project); invalidate(project) }
        start()
    }

    func recordPrompt(_ text: String, for request: WorktreeArtworkRequest) {
        guard enabled, let prompt = AgentHookPrompt.bounded(text) else { return }
        latestPrompts[request.path] = prompt
        guard
              let request = requests.first(where: { $0.path == request.path }),
              !request.mapFolder, let project = request.project else { return }
        guard contexts[request.path] == nil, maps[key(project)]?.contextualPaths.contains(request.path) != true else { return }
        contexts[request.path] = prompt
        invalidate(project)
        start()
    }

    func retryHistory(for request: WorktreeArtworkRequest) {
        guard enabled, let request = requests.first(where: { $0.path == request.path }),
              !request.mapFolder, contexts[request.path] == nil, let project = request.project,
              maps[key(project)]?.contextualPaths.contains(request.path) != true else { return }
        checkedHistory.remove(request.path)
        invalidate(project)
        start()
    }

    func regenerate(_ request: WorktreeArtworkRequest) {
        guard enabled, let request = requests.first(where: { $0.path == request.path }),
              request.mapVisible, !request.mapFolder, let project = request.project else { return }
        replaced.insert(request.path)
        refreshHistory.insert(request.path)
        regeneratingPaths.insert(request.path)
        invalidate(project)
        start()
    }

    private func invalidate(_ project: ProjectArtworkSource) {
        let k = key(project)
        dirty.insert(k)
        revisions[k, default: 0] &+= 1
        for request in members(project) { failures[request.path] = nil }
    }

    private var nextProject: ProjectArtworkSource? {
        guard enabled, active else { return nil }
        return projects.first { dirty.contains(key($0)) }
    }
    private func start() {
        guard worker == nil, nextProject != nil else { return }
        worker = Task { [self] in
            defer { worker = nil; start() }
            do { try await Task.sleep(for: debounce) } catch { return }
            while !Task.isCancelled, let project = nextProject { await render(project) }
        }
    }

    private func render(_ project: ProjectArtworkSource) async {
        generatingProject = project
        defer { generatingProject = nil }
        let k = key(project), revision = revisions[key(project), default: 0]
        let worktrees = members(project)
        do {
            for request in worktrees where !request.mapFolder && (!checkedHistory.contains(request.path) || refreshHistory.contains(request.path)) {
                let captured = latestPrompts[request.path]
                let prior = await history(request)
                try Task.checkCancellation()
                guard revisions[k, default: 0] == revision else { return }
                checkedHistory.insert(request.path)
                if refreshHistory.contains(request.path) {
                    contexts[request.path] = latestPrompts[request.path] != captured ? latestPrompts[request.path]
                        : prior.flatMap(AgentHookPrompt.bounded) ?? latestPrompts[request.path] ?? contexts[request.path]
                } else if contexts[request.path] == nil {
                    contexts[request.path] = latestPrompts[request.path] ?? prior.flatMap(AgentHookPrompt.bounded)
                }
            }
            let layout = slots(project)
            let existing = maps[k]
            let visiblePaths = Set(layout.map(\.path))
            let requested = replaced.intersection(visiblePaths)
            let unavailable = requested.filter { contexts[$0] == nil }
            for path in unavailable {
                replaced.remove(path)
                refreshHistory.remove(path)
                regeneratingPaths.remove(path)
                failures[path] = "No user task context is available yet. Submit a prompt before regenerating the map landmark."
            }
            let newlyContextual = Set(layout.filter { $0.isConnector != true && contexts[$0.path] != nil
                && existing?.contextualPaths.contains($0.path) != true }.map(\.path))
            let changing = requested.subtracting(unavailable).union(newlyContextual)
            // A task or the project root starts the map; every worktree then gets its own region.
            guard layout.contains(where: \.hasLandmark) else { dirty.remove(k); return }
            if let existing, existing.slots == layout, changing.isEmpty,
               existing.regionRevision == WorktreeMapRegionIdentity.revision,
               WorktreeMapRaster.hasCompleteCanvas(existing.image) { dirty.remove(k); return }
            let regionIDs = WorktreeMapRegionIdentity.assign(paths: worktrees.filter { !$0.mapFolder }.map(\.path),
                preserving: existing?.regionIDs ?? [:])
            let rows = layout.map { slot in
                WorktreeMapRow(path: slot.path, name: slot.name, height: slot.height, context: contexts[slot.path],
                    isConnector: slot.isConnector == true, regionID: regionIDs[slot.path])
            }
            let previousRegions = existing?.regionRevision == WorktreeMapRegionIdentity.revision ? existing?.landmarks ?? [:] : [:]
            let preserved = previousRegions.filter { visiblePaths.contains($0.key) && !changing.contains($0.key) }
            let data = try await generate(.init(rows: rows, project: project, style: style, theme: theme,
                preservedPaths: Set(preserved.keys),
                preservedRegions: try preserved.mapValues(WorktreeMapRaster.png)))
            try Task.checkCancellation()
            guard revisions[k, default: 0] == revision, projects.contains(project) else { return }
            guard let generated = NSImage(data: data), WorktreeMapRaster.hasCompleteCanvas(generated) else {
                throw ImageCreatorWorktreeIcon.Failure.invalidImage
            }
            let composed = try WorktreeMapRaster.compose(rows: rows, generated: generated, preserving: preserved)
            let slices = try WorktreeMapRaster.slices(composed, rows: rows)
            let registeredPaths = Set(worktrees.map(\.path))
            var landmarks = previousRegions.filter { registeredPaths.contains($0.key) && !changing.contains($0.key) }
            for slot in layout where landmarks[slot.path] == nil { landmarks[slot.path] = slices[slot.path] }
            let contextualPaths = (existing?.contextualPaths ?? []).union(layout.filter { contexts[$0.path] != nil }.map(\.path))
                .intersection(registeredPaths)
            let map = Map(slots: layout, image: composed, landmarks: landmarks, regionIDs: regionIDs,
                contextualPaths: contextualPaths, regionRevision: WorktreeMapRegionIdentity.revision)
            maps[k] = map
            for (path, image) in slices { images[path] = image }
            dirty.remove(k)
            replaced.subtract(changing)
            refreshHistory.subtract(changing)
            regeneratingPaths.subtract(changing)
            save(map, key: k)
        } catch {
            if Task.isCancelled { return }
            guard revisions[k, default: 0] == revision else { return }
            // Apple generation can require the foreground. Keep background
            // failures pending so activation can retry them without a busy loop.
            guard active else { return }
            dirty.remove(k)
            for request in worktrees {
                failures[request.path] = error.localizedDescription
                regeneratingPaths.remove(request.path)
            }
        }
    }

    private func file(_ key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private func load(_ project: ProjectArtworkSource, restoreDisplayedPixels: Bool = false) {
        loadCached(project, restoreDisplayedPixels: restoreDisplayedPixels)
        guard project.mapStyle != nil, members(project).contains(where: { images[$0.path] == nil }) else { return }
        // Per-project media added a cache-key component. Show the pre-medium map
        // during migration, but keep it under its own key so none of its regions
        // are reused when generating the new medium.
        var legacy = project
        legacy.mapStyle = nil
        loadCached(legacy)
    }

    private func publish(_ map: Map, for project: ProjectArtworkSource, replacing: Bool) {
        guard WorktreeMapRaster.hasCompleteCanvas(map.image) else { return }
        let paths = Set(requests.filter { $0.project?.path == project.path }.map(\.path))
        guard map.slots.contains(where: { paths.contains($0.path) && (replacing || images[$0.path] == nil) }),
              let slices = try? WorktreeMapRaster.slices(map.image, rows: map.slots.map(\.row)) else { return }
        for (path, image) in slices where paths.contains(path) && (replacing || images[path] == nil) {
            images[path] = image
        }
    }

    private func loadCached(_ project: ProjectArtworkSource, restoreDisplayedPixels: Bool = false) {
        let k = key(project)
        if let map = maps[k] {
            publish(map, for: project, replacing: restoreDisplayedPixels)
            return
        }
        guard loaded.insert(k).inserted,
              let handle = try? FileHandle(forReadingFrom: file(k)) else { return }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024 * 1024),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              !saved.slots.isEmpty, Set(saved.slots.map(\.path)).count == saved.slots.count,
              saved.slots.reduce(0, { $0 + $1.height }) <= 32000,
              saved.slots.allSatisfy({ $0.height.isFinite && $0.height == WorktreeMapLayout.height($0.height) }),
              let image = NSImage(data: saved.image) else { return }
        image.size = .init(width: WorktreeMapLayout.width, height: saved.slots.reduce(0) { $0 + $1.height })
        var landmarks: [String: NSImage] = [:]
        for (path, data) in saved.landmarks {
            guard let image = NSImage(data: data), let h = saved.heights[path],
                  h.isFinite, h == WorktreeMapLayout.height(h) else { continue }
            image.size = .init(width: WorktreeMapLayout.width, height: h)
            landmarks[path] = image
        }
        let map = Map(slots: saved.slots, image: image, landmarks: landmarks, regionIDs: saved.regionIDs ?? [:],
            contextualPaths: saved.contextualPaths ?? Set(saved.slots.filter(\.hasLandmark).map(\.path)),
            regionRevision: saved.regionRevision ?? 0)
        maps[k] = map
        // Earlier Apple fallbacks could save only landmark patches. Keep those
        // originals for repair, but do not publish the incomplete canvas.
        publish(map, for: project, replacing: restoreDisplayedPixels)
    }
    private func save(_ map: Map, key: String) {
        do {
            let saved = Saved(slots: map.slots, image: try WorktreeMapRaster.png(map.image),
                landmarks: try map.landmarks.mapValues(WorktreeMapRaster.png), heights: map.landmarks.mapValues { $0.size.height },
                regionIDs: map.regionIDs, contextualPaths: map.contextualPaths, regionRevision: map.regionRevision)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(saved).write(to: file(key), options: .atomic)
        } catch { /* A cache write must not discard successfully generated artwork. */ }
    }

    func waitUntilIdle() async { while let worker { await worker.value } }
}
