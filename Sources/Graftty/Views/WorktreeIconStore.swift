import AppKit
import Combine
import CryptoKit
import GrafttyKit
import OSLog

struct WorktreeArtworkRequest: Equatable, Sendable {
    let path: String
    let name: String
    let firstPaneSessionName: String?
    var project: ProjectArtworkSource? = nil
    var isMainCheckout = false
    var mapHeight: Double = 80
    var mapVisible = true
    var mapFolder = false
}

/// Artwork is scoped to a worktree; raw user context stays in memory only.
@MainActor
final class WorktreeIconStore: ObservableObject {
    static let shared: WorktreeIconStore = {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Graftty/WorktreeIcons", isDirectory: true)
        let history: @MainActor (WorktreeArtworkRequest) async -> String? = { request in
            guard let pane = request.firstPaneSessionName else { return nil }
            return await OffMainIO.run {
                WorktreeArtworkHistory.context(worktreePath: request.path, paneSessionName: pane)
            }
        }
        let maps = ProjectWorktreeMapStore(directory: cache.appendingPathComponent("maps-v1"),
            history: history, generate: ProjectWorktreeMapGenerator.generate)
        let store = WorktreeIconStore(
            directory: cache.appendingPathComponent("v5"),
            legacyDirectory: cache.appendingPathComponent("v4"),
            history: history,
            generate: WorktreeArtworkGenerator.generate, maps: maps
        )
        let preferences = WorktreeArtworkPreferences()
        store.configure(enabled: preferences.isEnabled, style: preferences.style)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification))
            .sink { [weak store] _ in
                Task { @MainActor in
                    guard let store else { return }
                    store.update(worktrees: store.worktrees, isActive: NSApplication.shared.isActive)
                }
            }
            .store(in: &store.lifecycleSubscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .sink { [weak store] _ in
                Task { @MainActor in
                    let preferences = WorktreeArtworkPreferences()
                    store?.configure(enabled: preferences.isEnabled, style: preferences.style)
                }
            }
            .store(in: &store.lifecycleSubscriptions)
        return store
    }()

    @Published private(set) var images: [String: NSImage] = [:]
    @Published private(set) var regeneratingPaths = Set<String>()
    @Published private(set) var failures: [String: String] = [:]
    private let mapStore: ProjectWorktreeMapStore?
    private let directory: URL
    private let legacyDirectory: URL?
    private let history: @MainActor (WorktreeArtworkRequest) async -> String?
    private let generate: @MainActor (String, String, WorktreeArtworkStyle, UInt64, WorktreeArtworkTheme?, ProjectArtworkSource?) async throws -> Data
    private var worktrees: [WorktreeArtworkRequest] = []
    private var contexts: [String: String] = [:]
    private var latestPrompts: [String: String] = [:]
    private var refreshContext = Set<String>()
    private var revisions: [String: Int] = [:]
    private var variations: [String: UInt64] = [:]
    private var completed = Set<String>()
    private var checkedHistory = Set<String>()
    private var isActive = false
    private var isEnabled = true
    private var style: WorktreeArtworkStyle = .illustration
    private var theme: WorktreeArtworkTheme?
    private var generationUnavailable = false
    private var worker: Task<Void, Never>?
    private var lifecycleSubscriptions = Set<AnyCancellable>()
    private static let logger = Logger(subsystem: "com.graftty", category: "WorktreeIcons")

    init(directory: URL, legacyDirectory: URL? = nil,
         history: @escaping @MainActor (WorktreeArtworkRequest) async -> String? = { _ in nil },
         generate: @escaping @MainActor (String, String, WorktreeArtworkStyle, UInt64, WorktreeArtworkTheme?, ProjectArtworkSource?) async throws -> Data, maps: ProjectWorktreeMapStore? = nil) {
        self.directory = directory
        self.legacyDirectory = legacyDirectory
        self.history = history
        self.generate = generate
        self.mapStore = maps
        if let maps {
            maps.$images.sink { [weak self] in self?.images = $0 }.store(in: &lifecycleSubscriptions)
            maps.$regeneratingPaths.sink { [weak self] in self?.regeneratingPaths = $0 }.store(in: &lifecycleSubscriptions)
            maps.$failures.sink { [weak self] in self?.failures = $0 }.store(in: &lifecycleSubscriptions)
        }
    }

    static func name(for worktree: WorktreeEntry, repoPath: String) -> String? {
        guard worktree.state.hasOnDiskWorktree, worktree.path != repoPath else { return nil }
        return SidebarWorktreeLabel.managedRelativeName(forPath: worktree.path, inRepoAtPath: repoPath)
            ?? URL(fileURLWithPath: worktree.path).lastPathComponent
    }

    static func request(for worktree: WorktreeEntry, repoPath: String, project: ProjectArtworkSource? = nil) -> WorktreeArtworkRequest? {
        guard let name = name(for: worktree, repoPath: repoPath) else { return nil }
        let pane = worktree.splitTree.allLeaves.first.flatMap { worktree.paneSessions[$0] }
        return WorktreeArtworkRequest(path: worktree.path, name: name,
            firstPaneSessionName: pane.map { ZmxLauncher.sessionName(for: $0) }, project: project)
    }

    func update(worktrees: [WorktreeArtworkRequest], isActive: Bool) {
        if let mapStore {
            self.worktrees = worktrees
            self.isActive = isActive
            mapStore.update(worktrees: worktrees, isActive: isActive)
            return
        }
        var seen = Set<String>()
        let priorRequests = Dictionary(self.worktrees.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let prior = priorRequests.mapValues(\.firstPaneSessionName)
        self.worktrees = worktrees.filter { !$0.path.isEmpty && seen.insert($0.path).inserted }
        for request in self.worktrees where (prior[request.path] ?? nil) != request.firstPaneSessionName {
            checkedHistory.remove(request.path)
            if contexts[request.path] == nil {
                revisions[request.path, default: 0] &+= 1
            }
        }
        for request in self.worktrees where priorRequests[request.path]?.project != request.project {
            revisions[request.path, default: 0] &+= 1
            completed.remove(request.path)
            failures[request.path] = nil
            checkedHistory.remove(request.path)
            if !generationUnavailable, images[request.path] != nil { regeneratingPaths.insert(request.path) }
        }
        regeneratingPaths.formIntersection(seen)
        self.isActive = isActive
        for request in self.worktrees where !completed.contains(request.path) && !refreshContext.contains(request.path) {
            if let image = loadCachedImage(for: request.path, in: imageDirectory(for: request)) {
                images[request.path] = image
                completed.insert(request.path)
                regeneratingPaths.remove(request.path)
            } else if images[request.path] == nil {
                if let theme {
                    let previousDirectories = [styleDirectory, unthemedStyleDirectory.appendingPathComponent(theme.colorCacheKey),
                                               unthemedStyleDirectory]
                    for directory in previousDirectories {
                        if let image = loadCachedImage(for: request.path, in: directory) {
                            images[request.path] = image
                            break
                        }
                    }
                }
                if images[request.path] == nil, style == .illustration, let legacyDirectory,
                   let image = NSImage(contentsOf: fileURL(for: request.name, in: legacyDirectory)) {
                    images[request.path] = image
                }
            }
        }
        if !isActive || self.worktrees.isEmpty { worker?.cancel() }
        startIfNeeded()
    }

    func configure(enabled: Bool, style: WorktreeArtworkStyle) {
        if let mapStore { mapStore.configure(enabled: enabled, style: style); return }
        guard isEnabled != enabled || self.style != style else { return }
        isEnabled = enabled
        if !enabled || self.style != style { worker?.cancel() }
        if self.style != style {
            self.style = style
            images.removeAll()
            failures.removeAll()
            completed.removeAll()
            checkedHistory.removeAll()
            refreshContext.removeAll()
            variations.removeAll()
            regeneratingPaths.removeAll()
        }
        update(worktrees: worktrees, isActive: isActive)
    }

    func configure(theme: WorktreeArtworkTheme) {
        if let mapStore { mapStore.configure(theme: theme); return }
        guard self.theme != theme else { return }
        let affected = worktrees.filter { $0.project == nil || self.theme?.backdropCacheKey != theme.backdropCacheKey }
        self.theme = theme
        guard !affected.isEmpty else { return }
        worker?.cancel()
        for request in affected {
            completed.remove(request.path)
            failures[request.path] = nil
            checkedHistory.remove(request.path)
        }
        generationUnavailable = false
        regeneratingPaths.formUnion(affected.filter { images[$0.path] != nil }.map(\.path))
        update(worktrees: worktrees, isActive: isActive)
    }

    private var unthemedStyleDirectory: URL { directory.appendingPathComponent(style.rawValue) }

    private var styleDirectory: URL {
        theme.map { unthemedStyleDirectory.appendingPathComponent($0.cacheKey) } ?? unthemedStyleDirectory
    }

    private func imageDirectory(for request: WorktreeArtworkRequest) -> URL {
        guard let project = request.project else { return styleDirectory }
        return unthemedStyleDirectory.appendingPathComponent(theme?.backdropCacheKey ?? "unthemed")
            .appendingPathComponent("project-v1-" + project.cacheKey)
    }

    func regenerate(_ request: WorktreeArtworkRequest) {
        if let mapStore { mapStore.regenerate(request); return }
        guard isEnabled, let index = worktrees.firstIndex(where: { $0.path == request.path }) else { return }
        worktrees[index] = request
        revisions[request.path, default: 0] &+= 1
        variations[request.path] = WorktreeArtworkIdentity.nextVariation(after: variations[request.path, default: 0])
        refreshContext.insert(request.path)
        regeneratingPaths.insert(request.path)
        completed.remove(request.path)
        failures[request.path] = nil
        generationUnavailable = false
        startIfNeeded()
    }

    func retryHistory(for request: WorktreeArtworkRequest) {
        if let mapStore { mapStore.retryHistory(for: request); return }
        guard isEnabled, contexts[request.path] == nil, !completed.contains(request.path),
              failures[request.path] == nil else { return }
        checkedHistory.remove(request.path)
        revisions[request.path, default: 0] &+= 1
        startIfNeeded()
    }

    func recordPrompt(_ text: String, for request: WorktreeArtworkRequest) {
        if let mapStore { mapStore.recordPrompt(text, for: request); return }
        guard isEnabled, let prompt = AgentHookPrompt.bounded(text) else { return }
        latestPrompts[request.path] = prompt
        guard !completed.contains(request.path), failures[request.path] == nil,
              contexts[request.path] == nil else { return }
        contexts[request.path] = prompt
        startIfNeeded()
    }

    private var nextRequest: WorktreeArtworkRequest? {
        guard isEnabled, isActive, !generationUnavailable else { return nil }
        return worktrees.first {
            !completed.contains($0.path) && failures[$0.path] == nil
                && (refreshContext.contains($0.path) || contexts[$0.path] != nil || !checkedHistory.contains($0.path))
        }
    }

    private func startIfNeeded() {
        guard worker == nil, nextRequest != nil else { return }
        worker = Task { [self] in
            await generateMissing()
            worker = nil
            startIfNeeded()
        }
    }

    private func generateMissing() async {
        while !Task.isCancelled, let request = nextRequest {
            let path = request.path
            let revision = revisions[path, default: 0]
            let variation = variations[path, default: 0]
            if contexts[path] == nil || refreshContext.contains(path) {
                let capturedBeforeRead = latestPrompts[path]
                let prior = await history(request)
                // A foreground prompt received during the read takes priority.
                if Task.isCancelled { return }
                guard revisions[path, default: 0] == revision else { continue }
                checkedHistory.insert(path)
                if refreshContext.contains(path) {
                    if latestPrompts[path] != capturedBeforeRead {
                        contexts[path] = latestPrompts[path]
                    } else {
                        contexts[path] = prior.flatMap(AgentHookPrompt.bounded) ?? latestPrompts[path] ?? contexts[path]
                    }
                } else if contexts[path] == nil, let prior {
                    contexts[path] = AgentHookPrompt.bounded(prior)
                }
            }
            guard worktrees.contains(where: { $0.path == path }), let context = contexts[path] else {
                refreshContext.remove(path)
                regeneratingPaths.remove(path)
                continue
            }
            do {
                let data = try await generate(request.name, context, style, variation, theme, request.project)
                try Task.checkCancellation()
                guard revisions[path, default: 0] == revision else { continue }
                guard worktrees.contains(where: { $0.path == path }) else { continue }
                guard let image = NSImage(data: data) else { throw ImageCreatorWorktreeIcon.Failure.invalidImage }
                images[path] = image
                completed.insert(path)
                refreshContext.remove(path)
                regeneratingPaths.remove(path)
                do {
                    let cacheDirectory = imageDirectory(for: request)
                    try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                    let imageURL = fileURL(for: path, in: cacheDirectory)
                    try data.write(to: imageURL, options: .atomic)
                    try String(variation).write(to: imageURL.appendingPathExtension("variation"), atomically: true, encoding: .utf8)
                } catch {
                    Self.logger.error("Could not cache worktree artwork: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                if Task.isCancelled { return }
                guard revisions[path, default: 0] == revision else { continue }
                contexts[path] = nil
                failures[path] = error.localizedDescription
                refreshContext.remove(path)
                regeneratingPaths.remove(path)
                if case ImageCreatorWorktreeIcon.Failure.unavailable = error {
                    generationUnavailable = true
                    regeneratingPaths.removeAll()
                }
                Self.logger.error("Worktree artwork failed for \(path, privacy: .private(mask: .hash)): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func waitUntilIdle() async {
        if let mapStore { await mapStore.waitUntilIdle(); return }
        while let worker { await worker.value }
    }

    private func loadCachedImage(for path: String, in directory: URL) -> NSImage? {
        let url = fileURL(for: path, in: directory)
        guard let image = NSImage(contentsOf: url) else { return nil }
        let metadata = url.appendingPathExtension("variation")
        variations[path] = (try? String(contentsOf: metadata, encoding: .utf8)).flatMap(UInt64.init) ?? 0
        return image
    }

    private func fileURL(for value: String, in directory: URL) -> URL {
        let key = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(key).appendingPathExtension("png")
    }
}
