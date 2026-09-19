import AppKit
import Testing
@testable import Graftty

@Suite("Project worktree maps")
@MainActor
struct ProjectWorktreeMapTests {
    @Test("@spec LAYOUT-2.114: When composing a project map, the application shall place independently generated regions within their exact worktree row boundaries, keep focal artwork in the first 80 points, and reuse saved regions during reordering without another provider call.")
    func independentRegionsAlignToRowsAndReuseSavedArtwork() async throws {
        let rows = [WorktreeMapRow(path: "a", name: "A", height: 104, context: "A"),
                    WorktreeMapRow(path: "b", name: "B", height: 160, context: "B")]
        let input = WorktreeMapGeneration(rows: rows, project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: [])
        let data = try await ProjectWorktreeMapGenerator.alignedRegions(input, direction: .harbor, preferred: { row, prompt in
            #expect(prompt.contains("exactly one region"))
            return try WorktreeMapRaster.png(Self.regionColor(row.path == "a" ? .red : .blue))
        }, fallback: { _, _ in Issue.record("Unexpected fallback"); return Data() })
        let image = try #require(NSImage(data: data))
        image.size = .init(width: 320, height: 264)
        #expect(try pixel(image, y: 103).redComponent > 0.95)
        #expect(try pixel(image, y: 104).blueComponent > 0.95)
        #expect(try pixel(image, y: 263).blueComponent > 0.95)
        let slices = try WorktreeMapRaster.slices(image, rows: rows)
        let reordered = WorktreeMapGeneration(rows: rows.reversed(), project: input.project, style: input.style,
            theme: nil, preservedPaths: ["a", "b"],
            preservedRegions: try slices.mapValues(WorktreeMapRaster.png))
        let restored = try await ProjectWorktreeMapGenerator.alignedRegions(reordered, direction: .harbor,
            preferred: { _, _ in Issue.record("Cached rows should not generate"); return Data() },
            fallback: { _, _ in Issue.record("Cached rows should not generate"); return Data() })
        let newImage = try #require(NSImage(data: restored))
        newImage.size = image.size
        #expect(try pixel(newImage, y: 159).blueComponent > 0.95)
        #expect(try pixel(newImage, y: 160).redComponent > 0.95)
    }

    private static func regionColor(_ color: NSColor) throws -> NSImage {
        try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(color.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 80))
        }
    }

    @Test func regionGenerationBoundsConcurrencyAndFallsBackOnlyForFailedRegions() async throws {
        let rows = (0..<4).map { WorktreeMapRow(path: "\($0)", name: "Task", height: 80, context: "Task") }
        let input = WorktreeMapGeneration(rows: rows, project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: [])
        var active = 0, peak = 0
        var fallbacks: [String] = []
        let data = try await ProjectWorktreeMapGenerator.alignedRegions(input, direction: .harbor, preferred: { row, _ in
            active += 1
            peak = max(peak, active)
            defer { active -= 1 }
            try await Task.sleep(for: .milliseconds(10))
            if row.path == "1" { throw ImageCreatorWorktreeIcon.Failure.unavailable }
            if row.path == "2" { return Data() }
            return try WorktreeMapRaster.png(Self.regionColor(.red))
        }, fallback: { row, _ in
            #expect(active == 0)
            fallbacks.append(row.path)
            return try WorktreeMapRaster.png(solid(.blue))
        })
        #expect(peak == 2)
        #expect(fallbacks == ["1", "2"])
        #expect(WorktreeMapRaster.hasCompleteCanvas(try #require(NSImage(data: data))))
    }

    @Test func cancelledRegionGenerationNeverStartsAppleFallback() async throws {
        let input = WorktreeMapGeneration(rows: [.init(path: "a", name: "A", height: 80, context: "A")],
            project: .init(path: "/project", avatar: nil), style: .illustration, theme: nil, preservedPaths: [])
        await #expect(throws: CancellationError.self) {
            try await ProjectWorktreeMapGenerator.alignedRegions(input, direction: .harbor,
                preferred: { _, _ in throw CancellationError() },
                fallback: { _, _ in Issue.record("Cancellation must not fall back"); return Data() })
        }
    }

    @Test("@spec LAYOUT-2.94: While the application is active and artwork is enabled, the application shall generate pending project maps serially from worktree names and available user prompts, and reuse cached maps across launches.")
    func projectsGenerateSeriallyAndWaitWhileDisabledOrInactive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = ["one", "two"].map {
            WorktreeArtworkRequest(path: "/\($0)/branch", name: "branch", firstPaneSessionName: nil,
                project: .init(path: "/\($0)", avatar: nil))
        }
        var active = 0, calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "User task" }) { _ in
            active += 1
            calls += 1
            #expect(active == 1)
            await Task.yield()
            active -= 1
            return try WorktreeMapRaster.png(solid(.red))
        }
        store.update(worktrees: requests, isActive: false)
        await store.waitUntilIdle()
        #expect(calls == 0)
        store.configure(enabled: false, style: .illustration)
        store.update(worktrees: requests, isActive: true)
        await store.waitUntilIdle()
        #expect(calls == 0)
        store.configure(enabled: true, style: .illustration)
        await store.waitUntilIdle()
        #expect(calls == 2)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files.count == 2)
        for file in files { #expect(try !String(contentsOf: file, encoding: .utf8).contains("User task")) }
    }

    @Test("@spec LAYOUT-2.106: When a project map extends behind the sidebar header, the application shall reserve a terrain-only header section and preserve existing worktree landmarks below it.")
    func addingHeaderPreservesLandmarksAndDoesNotReadHeaderHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectArtworkSource(path: "/header-project", avatar: nil)
        let worktree = WorktreeArtworkRequest(path: "task", name: "Task", firstPaneSessionName: nil, project: project)
        let header = WorktreeMapLayout.header(project: project)
        var inputs: [WorktreeMapGeneration] = []
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: {
            #expect($0.path != header.path)
            return "Build the map"
        }) { input in
            inputs.append(input)
            return try WorktreeMapRaster.png(solid(inputs.count == 1 ? .red : .blue))
        }
        store.update(worktrees: [worktree], isActive: true)
        await store.waitUntilIdle()
        store.update(worktrees: [header, worktree], isActive: true)
        await store.waitUntilIdle()
        #expect(inputs.last?.rows.map(\.path) == [header.path, worktree.path])
        #expect(inputs.last?.rows.first?.context == nil)
        #expect(inputs.last?.preservedPaths == [worktree.path])
        #expect(store.images[header.path]?.size.height == CGFloat(WorktreeMapLayout.headerHeight))
        #expect(try pixel(store.images[worktree.path], y: 40).redComponent > 0.95)
    }

    @Test("@spec LAYOUT-2.107: If a map provider returns incomplete transparent artwork, then the application shall retain its previous complete map and report generation failure.")
    func incompleteProviderImageCannotEraseExistingMap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "task", name: "Task", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil))
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Build a map" }) { _ in
            calls += 1
            let image = calls == 1 ? solid(.red) : try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { _ in }
            return try WorktreeMapRaster.png(image)
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        let previous = store.images[request.path]
        store.regenerate(request)
        await store.waitUntilIdle()
        #expect(store.images[request.path] === previous)
        #expect(store.failures[request.path] != nil)
    }

    @Test("Incomplete legacy map caches retain landmark pixels while their canvas is repaired")
    func incompleteCacheIsRepairedWithoutPublishingBlankRegions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "task", name: "Task", firstPaneSessionName: nil,
            project: .init(path: "/repair", avatar: nil))
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Build a map" }) { _ in
            try WorktreeMapRaster.png(solid(.red))
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let empty = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { _ in }
        saved["image"] = try WorktreeMapRaster.png(empty).base64EncodedString()
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        var calls = 0
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls += 1
            #expect(input.preservedPaths == [request.path])
            return try WorktreeMapRaster.png(solid(.blue))
        }
        restored.update(worktrees: [request], isActive: true)
        #expect(restored.images.isEmpty)
        await restored.waitUntilIdle()
        #expect(calls == 1)
        #expect(try pixel(restored.images[request.path], y: 40).redComponent > 0.95)
        #expect(WorktreeMapRaster.hasCompleteCanvas(try #require(restored.images[request.path])))
    }

    @Test func appleFallbackPaintsHeaderAndQuietRowsBehindPreservedLandmarks() async throws {
        let rows: [WorktreeMapRow] = [
            .init(path: "header", name: "Canopy", height: 128, context: nil, isConnector: true),
            .init(path: "task", name: "Task", height: 80, context: "Build a garden"),
            .init(path: "quiet", name: "Waiting", height: 240, context: nil),
        ]
        let input = WorktreeMapGeneration(rows: rows, project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: ["task"],
            preservedRegions: ["task": try WorktreeMapRaster.png(solid(.red))])
        var calls = 0
        let data = try await ProjectWorktreeMapGenerator.alignedRegions(input, direction: .harbor,
            preferred: { _, _ in Data() }, fallback: { row, _ in
                calls += 1
                #expect(["Canopy", "Waiting"].contains(row.name))
                return try WorktreeMapRaster.png(solid(row.name == "Waiting" ? .green : .blue))
            })
        let image = try #require(NSImage(data: data))
        image.size = .init(width: 320, height: 448)
        #expect(WorktreeMapRaster.hasCompleteCanvas(image))
        let slices = try WorktreeMapRaster.slices(image, rows: rows)
        #expect(try pixel(slices["header"], y: 40).blueComponent > 0.95)
        #expect(try pixel(slices["quiet"], y: 40).greenComponent > 0.95)
        #expect(try pixel(slices["quiet"], y: 180).greenComponent > 0.95)
        #expect(try pixel(slices["task"], y: 40).redComponent > 0.95)
        #expect(calls == 2)
    }

    @Test("@spec LAYOUT-2.109: When worktrees are reordered, added, hidden, or restored from cache, the application shall retain their assigned region identities and preserve their existing region pixels, including regions awaiting task context.")
    func regionAssignmentsAndUncontextualizedPixelsSurviveReorderingAndCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectArtworkSource(path: "/regions", avatar: nil)
        let a = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil, project: project)
        let b = WorktreeArtworkRequest(path: "b", name: "B", firstPaneSessionName: nil, project: project)
        let c = WorktreeArtworkRequest(path: "0", name: "New", firstPaneSessionName: nil, project: project)
        var calls: [WorktreeMapGeneration] = []
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { $0.path == "a" ? "Build a garden" : nil }) { input in
            calls.append(input)
            return try WorktreeMapRaster.png(solid(.red))
        }
        store.update(worktrees: [a, b], isActive: true)
        await store.waitUntilIdle()
        let originalIDs = Dictionary(uniqueKeysWithValues: calls[0].rows.map { ($0.path, $0.regionID) })
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls.append(input)
            return try WorktreeMapRaster.png(solid(.blue))
        }
        restored.update(worktrees: [c, b, a], isActive: true)
        await restored.waitUntilIdle()
        let latest = try #require(calls.last)
        #expect(Set(latest.rows.compactMap(\.regionID)).count == 3)
        for row in latest.rows where row.path != c.path { #expect(row.regionID == originalIDs[row.path]!) }
        #expect(latest.preservedPaths == [a.path, b.path])
        #expect(try pixel(restored.images[b.path], y: 40).redComponent > 0.95)
        let bID = latest.rows.first { $0.path == b.path }?.regionID
        var hiddenB = b
        hiddenB.mapVisible = false
        restored.update(worktrees: [c, hiddenB, a], isActive: true)
        await restored.waitUntilIdle()
        restored.recordPrompt("Review notifications", for: b)
        await restored.waitUntilIdle()
        restored.update(worktrees: [c, b, a], isActive: true)
        await restored.waitUntilIdle()
        #expect(calls.last?.rows.first { $0.path == b.path }?.regionID == bID)
        #expect(calls.last?.preservedPaths == [a.path, c.path])
        #expect(calls.last?.rows.first { $0.path == b.path }?.context == "Review notifications")
    }

    @Test("Legacy maps remain visible while their distinct region identities are generated once")
    func legacyMapMigratesOnceWithoutPreservingTheOldUniformArtwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "task", name: "Task", firstPaneSessionName: nil,
            project: .init(path: "/legacy", avatar: nil))
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Build a map" }) { _ in
            try WorktreeMapRaster.png(solid(.red))
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for key in ["regionRevision", "regionIDs", "contextualPaths"] { saved.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        var calls = 0
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls += 1
            #expect(input.preservedPaths.isEmpty)
            #expect(input.rows.first?.regionID == 0)
            return try WorktreeMapRaster.png(solid(.blue))
        }
        restored.update(worktrees: [request], isActive: true)
        #expect(try pixel(restored.images[request.path], y: 40).redComponent > 0.95)
        await restored.waitUntilIdle()
        #expect(calls == 1)
        #expect(try pixel(restored.images[request.path], y: 40).blueComponent > 0.95)
        let reused = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { _ in
            Issue.record("Migrated maps must reuse their cache")
            return Data()
        }
        reused.update(worktrees: [request], isActive: true)
        await reused.waitUntilIdle()
        #expect(try pixel(reused.images[request.path], y: 40).blueComponent > 0.95)
    }

    @Test func regionIdentityAllocatorUsesDistinctColorsAndRetainsExistingAssignments() {
        let paths = (0..<16).map { "task-\($0)" }
        let original = WorktreeMapRegionIdentity.assign(paths: paths, preserving: [:])
        #expect(Set(original.values).count == paths.count)
        #expect(Set(original.values.map(WorktreeMapRegionIdentity.design)).count == paths.count)
        let updated = WorktreeMapRegionIdentity.assign(paths: ["new"] + paths.reversed(), preserving: original)
        for path in paths { #expect(updated[path] == original[path]) }
        #expect(updated["new"] == 16)
    }

    @Test("@spec LAYOUT-2.108: When generating a project map, the application shall assign every worktree a distinct region with a stable dominant color and large-scale terrain composition, including worktrees without task context, and keep connecting paths subordinate to those regions.")
    func mapPromptPrioritizesWholeRegionIdentityOverConnectingRoads() {
        let input = WorktreeMapGeneration(rows: [
            .init(path: "a", name: "Review", height: 80, context: "Review code"),
            .init(path: "b", name: "Notifications", height: 80, context: nil),
        ], project: .init(path: "/project", avatar: nil), style: .illustration, theme: nil,
           preservedPaths: [])
        let prompt = ProjectWorktreeMapGenerator.regionPrompt(input.rows[0], input: input, direction: .harbor)
        #expect(prompt.contains(WorktreeMapRegionIdentity.design(0)))
        #expect(prompt.contains("at least 70%"))
        #expect(prompt.contains("Connections occupy at most 10%"))
        #expect(prompt.contains("left 40%"))
        #expect(prompt.contains("between 45% and 65%"))
        #expect(prompt.contains("one landmark"))
        #expect(WorktreeMapRegionIdentity.design(0).contains("sparse"))
        #expect(!prompt.contains("No task context yet: draw quiet connecting terrain"))
    }

    @Test func fittingTallRowsKeepsTheFocalAreaAtTheTop() throws {
        let original = try WorktreeMapRaster.draw(size: .init(width: 320, height: 80)) { context in
            context.setFillColor(NSColor.red.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 40))
            context.setFillColor(NSColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 40, width: 320, height: 40))
        }
        let tall = try WorktreeMapRaster.fitRegion(original, height: 400)
        #expect(try pixel(tall, y: 20).redComponent > 0.95)
        #expect(try pixel(tall, y: 60).blueComponent > 0.95)
        #expect(try pixel(tall, y: 250).blueComponent > 0.95)
        #expect(WorktreeMapRaster.hasCompleteCanvas(tall))
    }

    @Test func extendingAndRestoringRegionsDoesNotRestartTheirTerrain() throws {
        func gradient(height: CGFloat) throws -> NSImage {
            try WorktreeMapRaster.draw(size: .init(width: 320, height: height)) { context in
                for y in 0..<Int(height * 2) {
                    let fraction = CGFloat(y) / (height * 2)
                    context.setFillColor(NSColor(deviceRed: fraction, green: 0, blue: 1 - fraction, alpha: 1).cgColor)
                    context.fill(CGRect(x: 0, y: CGFloat(y) / 2, width: 320, height: 0.5))
                }
            }
        }
        let short = try WorktreeMapRaster.fitRegion(gradient(height: 80), height: 160)
        #expect(abs(try pixel(short, y: 79).redComponent - pixel(short, y: 80).redComponent) < 0.03)
        let original = try gradient(height: 104)
        let fitted = try WorktreeMapRaster.fitRegion(original, height: 160)
        let composed = try WorktreeMapRaster.compose(rows: [.init(path: "a", name: "A", height: 160, context: "A")],
            generated: fitted, preserving: ["a": original])
        for y in [85, 95, 103, 104, 120] {
            #expect(abs(try pixel(composed, y: y).redComponent - pixel(fitted, y: y).redComponent) < 0.01)
        }
    }

    @Test("@spec LAYOUT-2.102: When a project map changes order or gains task context, the application shall generate one replacement from the ordered worktrees, retain existing landmarks, reuse its cache across launches, and discard results for obsolete layouts.")
    func mapsReuseCacheAndRebuildOnlyForChangedLayout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let a = WorktreeArtworkRequest(path: "/project/a", name: "A", firstPaneSessionName: "a", project: project)
        let b = WorktreeArtworkRequest(path: "/project/b", name: "B", firstPaneSessionName: "b", project: project)
        var calls: [WorktreeMapGeneration] = []
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { $0.name }) { input in
            calls.append(input)
            return try WorktreeMapRaster.png(solid(calls.count == 1 ? .red : .blue, height: 160))
        }
        store.update(worktrees: [a, b], isActive: true)
        await store.waitUntilIdle()
        #expect(calls.count == 1)
        store.update(worktrees: [a, b], isActive: true)
        await store.waitUntilIdle()
        #expect(calls.count == 1)
        store.update(worktrees: [b, a], isActive: true)
        await store.waitUntilIdle()
        #expect(calls.count == 2)
        #expect(calls.last?.rows.map(\.path) == [b.path, a.path])
        #expect(calls.last?.preservedPaths == [a.path, b.path])
        #expect(try pixel(store.images[a.path], y: 40).redComponent > 0.95)
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { _ in
            Issue.record("Cached map should not generate again")
            throw ImageCreatorWorktreeIcon.Failure.unavailable
        }
        restored.update(worktrees: [b, a], isActive: true)
        await restored.waitUntilIdle()
        #expect(try pixel(restored.images[a.path], y: 40).redComponent > 0.95)
        store.regenerate(a)
        #expect(store.regeneratingPaths.contains(a.path))
        await store.waitUntilIdle()
        #expect(calls.last?.preservedPaths == [b.path])
        #expect(try pixel(store.images[a.path], y: 40).blueComponent > 0.95)
        #expect(try pixel(store.images[b.path], y: 40).redComponent > 0.95)
        #expect(store.regeneratingPaths.isEmpty)
    }

    @Test func staleResultCannotOverwriteReorderedMap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let a = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil, project: project)
        let b = WorktreeArtworkRequest(path: "b", name: "B", firstPaneSessionName: nil, project: project)
        var continuation: CheckedContinuation<Data, any Error>?
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { $0.name }) { _ in
            calls += 1
            if calls == 1 { return try await withCheckedThrowingContinuation { continuation = $0 } }
            return try WorktreeMapRaster.png(solid(.blue, height: 160))
        }
        store.update(worktrees: [a, b], isActive: true)
        while continuation == nil { await Task.yield() }
        store.update(worktrees: [b, a], isActive: true)
        continuation?.resume(returning: try WorktreeMapRaster.png(solid(.red, height: 160)))
        await store.waitUntilIdle()
        #expect(calls == 2)
        #expect(try pixel(store.images[a.path], y: 40).blueComponent > 0.95)
    }

    @Test("@spec LAYOUT-2.115: When a project first adopts an artwork medium after restart, the application shall display its previous cached map until a replacement succeeds without reusing old regions in the new medium.", arguments: [false, true])
    func mediumMigrationDisplaysPreviousCache(replacementFails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = WorktreeArtworkRequest(path: "/project", name: "main", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil), isMainCheckout: true)
        let original = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { _ in
            try WorktreeMapRaster.png(solid(.red))
        }
        original.update(worktrees: [request], isActive: true)
        await original.waitUntilIdle()
        request.project?.mapStyle = .ink
        var calls = 0
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls += 1
            #expect(input.preservedRegions.isEmpty)
            #expect(input.preservedPaths.isEmpty)
            if replacementFails { throw ImageCreatorWorktreeIcon.Failure.unavailable }
            return try WorktreeMapRaster.png(solid(.blue))
        }
        restored.update(worktrees: [request], isActive: false)
        #expect(try pixel(restored.images[request.path], y: 40).redComponent > 0.95)
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        #expect(calls == 1)
        let color = try pixel(restored.images[request.path], y: 40)
        #expect(replacementFails ? color.redComponent > 0.95 : color.blueComponent > 0.95)
        let relaunched = ProjectWorktreeMapStore(directory: directory, history: { _ in nil }) { _ in
            Issue.record("Inactive cache loading must not generate")
            return Data()
        }
        relaunched.update(worktrees: [request], isActive: false)
        let cached = try pixel(relaunched.images[request.path], y: 40)
        #expect(replacementFails ? cached.redComponent > 0.95 : cached.blueComponent > 0.95)
    }

    @Test("@spec LAYOUT-2.116: When the application loses focus during map generation, the application shall let the current map finish, cache successful results, and defer retries and subsequent projects until the application becomes active.", arguments: [false, true])
    func losingFocusKeepsInFlightMap(backgroundFails: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let requests = ["one", "two"].map {
            WorktreeArtworkRequest(path: "/\($0)", name: "main", firstPaneSessionName: nil,
                project: .init(path: "/\($0)", avatar: nil), isMainCheckout: true)
        }
        var calls = 0
        var continuation: CheckedContinuation<Void, Never>?
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { _ in
            calls += 1
            if calls == 1 {
                await withCheckedContinuation { continuation = $0 }
                if backgroundFails { throw ImageCreatorWorktreeIcon.Failure.unavailable }
            }
            try Task.checkCancellation()
            return try WorktreeMapRaster.png(solid(.red))
        }
        store.update(worktrees: requests, isActive: true)
        while continuation == nil { await Task.yield() }
        store.update(worktrees: requests, isActive: false)
        continuation?.resume()
        await store.waitUntilIdle()
        #expect(calls == 1)
        #expect((store.images[requests[0].path] == nil) == backgroundFails)
        #expect(store.images[requests[1].path] == nil)
        store.update(worktrees: requests, isActive: true)
        await store.waitUntilIdle()
        #expect(calls == (backgroundFails ? 3 : 2))
        #expect(store.images[requests[0].path] != nil)
        #expect(store.images[requests[1].path] != nil)
        #expect(store.failures.isEmpty)
    }

    @Test("Returning to a cached project medium restores its pixels without generating again")
    func mediumRoundTripRestoresCachedPixels() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil, mapStyle: .ink))
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Task" }) { input in
            calls += 1
            return try WorktreeMapRaster.png(solid(input.project.mapStyle == .ink ? .red : .blue))
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        request.project?.mapStyle = .woodcut
        store.update(worktrees: [request], isActive: true)
        #expect(try pixel(store.images[request.path], y: 40).redComponent > 0.95)
        await store.waitUntilIdle()
        #expect(try pixel(store.images[request.path], y: 40).blueComponent > 0.95)
        request.project?.mapStyle = .ink
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(try pixel(store.images[request.path], y: 40).redComponent > 0.95)
        #expect(calls == 2)
    }

    @Test("Changing the generating project's medium cancels obsolete work")
    func changingMediumCancelsObsoleteGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var request = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil, mapStyle: .ink))
        var started = false, cancelled = false
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Task" }) { input in
            if input.project.mapStyle == .ink {
                started = true
                do { try await Task.sleep(for: .milliseconds(300)) }
                catch { cancelled = true; throw error }
            }
            return try WorktreeMapRaster.png(solid(.blue))
        }
        store.update(worktrees: [request], isActive: true)
        while !started { await Task.yield() }
        request.project?.mapStyle = .woodcut
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(cancelled)
        #expect(store.images[request.path] != nil)
    }

    @Test("Identical updates retain the in-flight map even when another project changes")
    func unchangedProjectDoesNotRestartGeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil))
        let other = WorktreeArtworkRequest(path: "other", name: "Other", firstPaneSessionName: nil,
            project: .init(path: "/other", avatar: nil))
        var continuation: CheckedContinuation<Data, any Error>?
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero,
            history: { $0.path == request.path ? "Build a garden" : nil }) { _ in
                calls += 1
                if calls == 1 { return try await withCheckedThrowingContinuation { continuation = $0 } }
                return try WorktreeMapRaster.png(solid(.blue))
            }
        store.update(worktrees: [request], isActive: true)
        while continuation == nil { await Task.yield() }
        store.update(worktrees: [request], isActive: true)
        store.update(worktrees: [request, other], isActive: true)
        continuation?.resume(returning: try WorktreeMapRaster.png(solid(.red)))
        await store.waitUntilIdle()
        #expect(calls == 1)
        #expect(try pixel(store.images[request.path], y: 40).redComponent > 0.95)
    }

    @Test("Hook requests without project metadata resolve the registered worktree", arguments: [false, true])
    func hookRequestsResolveRegisteredProject(retryHistory: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registered = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: "pane",
            project: .init(path: "/project", avatar: nil))
        let hook = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: "pane")
        var historyContext: String?
        var calls: [WorktreeMapGeneration] = []
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero,
            history: { _ in historyContext }) { input in
                calls.append(input)
                return try WorktreeMapRaster.png(solid(.red))
            }
        store.update(worktrees: [registered], isActive: true)
        await store.waitUntilIdle()
        #expect(calls.isEmpty)
        if retryHistory {
            historyContext = "Build a garden"
            store.retryHistory(for: hook)
        } else {
            store.recordPrompt("Build a garden", for: hook)
        }
        await store.waitUntilIdle()
        #expect(calls.count == 1)
        #expect(calls.first?.rows.first?.context == "Build a garden")
    }

    @Test("Switching back to a cached theme restores its map without generation")
    func cachedThemeReplacesDisplayedMap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil))
        let dark = WorktreeArtworkTheme(theme: GhosttyTheme(core: .init(
            backgroundRGB: .init(r: 0, g: 0, b: 0), foregroundRGB: .init(r: 1, g: 1, b: 1))))
        let light = WorktreeArtworkTheme(theme: GhosttyTheme(core: .init(
            backgroundRGB: .init(r: 1, g: 1, b: 1), foregroundRGB: .init(r: 0, g: 0, b: 0))))
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Build a garden" }) { _ in
            calls += 1
            return try WorktreeMapRaster.png(solid(calls == 1 ? .red : .blue))
        }
        store.configure(theme: dark)
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        store.configure(theme: light)
        await store.waitUntilIdle()
        #expect(try pixel(store.images[request.path], y: 40).blueComponent > 0.95)
        store.configure(theme: dark)
        await store.waitUntilIdle()
        #expect(calls == 2)
        #expect(try pixel(store.images[request.path], y: 40).redComponent > 0.95)
    }

    @Test("Regenerating without recovered task context retains the cached landmark")
    func missingContextCannotEraseCachedLandmark() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil))
        let original = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in "Build a garden" }) { _ in
            try WorktreeMapRaster.png(solid(.red))
        }
        original.update(worktrees: [request], isActive: true)
        await original.waitUntilIdle()
        var calls = 0
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { _ in
            calls += 1
            return try WorktreeMapRaster.png(solid(.blue))
        }
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        restored.regenerate(request)
        await restored.waitUntilIdle()
        #expect(calls == 0)
        #expect(restored.regeneratingPaths.isEmpty)
        #expect(restored.failures[request.path] != nil)
        #expect(try pixel(restored.images[request.path], y: 40).redComponent > 0.95)
    }

    @Test("Hidden worktrees retain cached landmarks while folder rows reserve terrain without reading history")
    func layoutUsesVisibleRowsAndRetainsHiddenLandmarksAcrossLaunches() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        var a = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil, project: project)
        let b = WorktreeArtworkRequest(path: "b", name: "B", firstPaneSessionName: nil, project: project)
        var folder = WorktreeArtworkRequest(path: "folder", name: "Folder", firstPaneSessionName: nil, project: project)
        folder.mapFolder = true
        folder.mapHeight = 44
        var calls: [WorktreeMapGeneration] = []
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { request in
            #expect(!request.mapFolder)
            return request.name
        }) { input in
            calls.append(input)
            return try WorktreeMapRaster.png(solid(calls.count == 1 ? .red : .blue,
                height: input.rows.reduce(0) { $0 + $1.height }))
        }
        store.update(worktrees: [a, b], isActive: true)
        await store.waitUntilIdle()
        a.mapVisible = false
        store.update(worktrees: [folder, a, b], isActive: true)
        await store.waitUntilIdle()
        #expect(calls.last?.rows.map(\.path) == [folder.path, b.path])
        #expect(calls.last?.rows.map(\.height) == [44, 80])
        #expect(calls.last?.rows.first?.context == nil)
        #expect(calls.last?.preservedPaths == [b.path])
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls.append(input)
            return try WorktreeMapRaster.png(solid(.blue, height: input.rows.reduce(0) { $0 + $1.height }))
        }
        restored.update(worktrees: [folder, a, b], isActive: true)
        await restored.waitUntilIdle()
        #expect(calls.count == 2)
        a.mapVisible = true
        a.mapHeight = 140
        restored.update(worktrees: [folder, a, b], isActive: true)
        await restored.waitUntilIdle()
        #expect(calls.last?.rows.map(\.height) == [44, 140, 80])
        #expect(calls.last?.preservedPaths == [folder.path, a.path, b.path])
        #expect(try pixel(restored.images[a.path], y: 40).redComponent > 0.95)
        #expect(try pixel(restored.images[a.path], y: 110).blueComponent > 0.95)
    }

    @Test func firstPromptUnlocksLandmarkAndFailureRetainsMap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "a", name: "A", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil))
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { _ in
            calls += 1
            if calls > 1 { throw ImageCreatorWorktreeIcon.Failure.unavailable }
            return try WorktreeMapRaster.png(solid(.red))
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(calls == 0)
        store.recordPrompt("Build a garden", for: request)
        await store.waitUntilIdle()
        #expect(calls == 1)
        store.regenerate(request)
        await store.waitUntilIdle()
        #expect(calls == 2)
        #expect(try pixel(store.images[request.path], y: 40).redComponent > 0.95)
        #expect(store.regeneratingPaths.isEmpty)
        #expect(store.failures[request.path] != nil)
    }

    @Test("@spec LAYOUT-2.100: When worktrees are reordered, the application shall rebuild their shared project map in the new order while preserving the pixels of existing regions and generating only missing or explicitly replaced regions.")
    func reorderPreservesLandmarkPixels() throws {
        let red = solid(.red), blue = solid(.blue)
        let rows = [WorktreeMapRow(path: "b", name: "B", height: 80, context: "B"),
                    WorktreeMapRow(path: "a", name: "A", height: 80, context: "A")]
        let result = try WorktreeMapRaster.compose(rows: rows, generated: solid(.green, height: 160),
                                                  preserving: ["a": red, "b": blue])
        let slices = try WorktreeMapRaster.slices(result, rows: rows)
        #expect(try pixel(slices["b"], y: 40).blueComponent > 0.95)
        #expect(try pixel(slices["a"], y: 40).redComponent > 0.95)
        #expect(try pixel(slices["a"], y: 0).greenComponent > 0.8)
    }

    @Test("@spec LAYOUT-2.101: While a project map is displayed, resizing the sidebar shall keep artwork at its saved scale and top-left origin, fading beyond its right and bottom edges without triggering image generation.")
    func expandingRowDoesNotStretchLandmark() throws {
        let rows = [WorktreeMapRow(path: "a", name: "A", height: 180, context: "A")]
        let result = try WorktreeMapRaster.compose(rows: rows, generated: solid(.green, height: 180),
                                                  preserving: ["a": solid(.red)])
        #expect(try pixel(result, y: 40).redComponent > 0.95)
        #expect(try pixel(result, y: 120).greenComponent > 0.95)
    }

    @Test func reorderingPreservesTerrainBelowTheLandmark() throws {
        let rows = [WorktreeMapRow(path: "a", name: "A", height: 240, context: "A")]
        let result = try WorktreeMapRaster.compose(rows: rows, generated: solid(.green, height: 240),
                                                  preserving: ["a": solid(.red, height: 240)])
        #expect(try pixel(result, y: 40).redComponent > 0.95)
        #expect(try pixel(result, y: 180).redComponent > 0.95)
        #expect(try pixel(result, y: 239).greenComponent > 0.8)
    }

    func solid(_ color: NSColor, height: CGFloat = 80) -> NSImage {
        let image = NSImage(size: .init(width: WorktreeMapLayout.width, height: height))
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        return image
    }

    func pixel(_ image: NSImage?, y: Int) throws -> NSColor {
        let image = try #require(image)
        var rect = CGRect(origin: .zero, size: image.size)
        let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        return try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2,
            y: Int(CGFloat(y) * CGFloat(bitmap.pixelsHigh) / image.size.height))?.usingColorSpace(.deviceRGB))
    }
}
