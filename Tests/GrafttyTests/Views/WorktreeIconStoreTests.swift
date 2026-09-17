import AppKit
import CryptoKit
import GrafttyKit
import Testing
@testable import Graftty

@Suite("Automatic worktree icons")
@MainActor
struct WorktreeIconStoreTests {
    @Test("@spec LAYOUT-2.69: While the application is active, it shall automatically generate missing local linked-worktree artwork from their names and available user-prompt context one at a time and reuse cached artwork across launches.")
    func generatesSeriallyAndReusesCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var calls: [String] = []
        var active = 0
        var maximumActive = 0
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { name, _, _, _, _ in
            active += 1
            maximumActive = max(maximumActive, active)
            calls.append(name)
            await Task.yield()
            active -= 1
            return png
        }
        store.update(worktrees: requests(["fix-login", "new-tabs", "fix-login"]), isActive: true)
        store.update(worktrees: requests(["fix-login", "new-tabs"]), isActive: true)
        await store.waitUntilIdle()
        #expect(calls == ["fix-login", "new-tabs"])
        #expect(maximumActive == 1)
        #expect(store.images["fix-login"] != nil)

        let restored = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { name, _, _, _, _ in
            calls.append(name)
            return png
        }
        restored.update(worktrees: requests(["fix-login", "new-tabs"]), isActive: true)
        await restored.waitUntilIdle()
        #expect(calls.count == 2)
        #expect(restored.images["new-tabs"] != nil)
    }

    @Test("@spec LAYOUT-2.70: If worktree artwork generation still fails after its permitted prompt fallback, then the application shall retain the normal sidebar indicators and avoid repeated automatic attempts for that worktree during the same launch.")
    func failureDoesNotLoopOrBlockOtherNames() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var calls: [String] = []
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { name, _, _, _, _ in
            calls.append(name)
            if name == "rejected" { throw TestFailure.rejected }
            return png
        }
        store.update(worktrees: requests(["rejected", "accepted"]), isActive: true)
        await store.waitUntilIdle()
        store.update(worktrees: requests(["rejected", "accepted"]), isActive: true)
        await store.waitUntilIdle()
        #expect(calls == ["rejected", "accepted"])
        #expect(store.images["rejected"] == nil)
        #expect(store.failures["rejected"] != nil)
        #expect(store.images["accepted"] != nil)
    }

    @Test("@spec LAYOUT-2.71: When the application becomes inactive, it shall cancel worktree icon generation, discard cancelled results, and resume missing icons when active again.")
    func pausesAndDiscardsCancelledResults() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var calls = 0
        var completion: CheckedContinuation<Data, Never>?
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                return await withCheckedContinuation { completion = $0 }
            }
            return png
        }
        store.update(worktrees: requests(["login"]), isActive: false)
        await store.waitUntilIdle()
        #expect(calls == 0)
        store.update(worktrees: requests(["login"]), isActive: true)
        while completion == nil { await Task.yield() }
        store.update(worktrees: requests(["login"]), isActive: false)
        completion?.resume(returning: png)
        await store.waitUntilIdle()
        #expect(store.images.isEmpty)
        #expect(store.failures.isEmpty)
        store.update(worktrees: requests(["login"]), isActive: true)
        await store.waitUntilIdle()
        #expect(calls == 2)
        #expect(store.images["login"] != nil)
    }

    @Test("@spec LAYOUT-2.72: When selecting worktrees for automatic artwork, the application shall include only local on-disk linked worktrees and derive visual identities from their names without repository paths.")
    func requestsUseNamesAndExcludeTransientAndStaleEntries() {
        let entries = [
            WorktreeEntry(path: "/private/project", branch: "feature"),
            WorktreeEntry(path: "/private/project/.worktrees/fix/login", branch: "unrelated"),
            WorktreeEntry(path: "/elsewhere/new-tabs", branch: "unrelated", state: .running),
            WorktreeEntry(path: "/private/project/.worktrees/creating", branch: "x", state: .creating),
            WorktreeEntry(path: "/private/project/.worktrees/deleting", branch: "x", state: .deleting),
            WorktreeEntry(path: "/private/project/.worktrees/stale", branch: "x", state: .stale),
        ]
        #expect(entries.compactMap { WorktreeIconStore.name(for: $0, repoPath: "/private/project") }
            == ["fix/login", "new-tabs"])
    }

    @Test func removedRequestsAreNotGenerated() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var calls: [String] = []
        var completion: CheckedContinuation<Data, Never>?
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { name, _, _, _, _ in
            calls.append(name)
            return await withCheckedContinuation { completion = $0 }
        }
        store.update(worktrees: requests(["first", "removed"]), isActive: true)
        while completion == nil { await Task.yield() }
        store.update(worktrees: requests([]), isActive: true)
        completion?.resume(returning: png)
        await store.waitUntilIdle()
        #expect(calls == ["first"])
        #expect(store.images.isEmpty)
    }

    @Test func invalidImageDataFallsBack() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { _, _, _, _, _ in Data("invalid".utf8) }
        store.update(worktrees: requests(["test"]), isActive: true)
        await store.waitUntilIdle()
        #expect(store.images.isEmpty)
        #expect(store.failures["test"] != nil)
    }

    @Test func unavailableGenerationStopsTheQueueButStillLoadsCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let seed = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { _, _, _, _, _ in png }
        seed.update(worktrees: requests(["cached"]), isActive: true)
        await seed.waitUntilIdle()
        var calls = 0
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { _, _, _, _, _ in
            calls += 1
            throw ImageCreatorWorktreeIcon.Failure.unavailable
        }
        store.update(worktrees: requests(["first", "second"]), isActive: true)
        await store.waitUntilIdle()
        store.update(worktrees: requests(["first", "second", "cached"]), isActive: true)
        await store.waitUntilIdle()
        #expect(calls == 1)
        #expect(store.images["cached"] != nil)
    }

    @Test func rapidReactivationWaitsForCancelledGenerationToFinish() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var calls = 0
        var completion: CheckedContinuation<Data, Never>?
        let store = WorktreeIconStore(directory: directory, history: { _ in "Existing user task" }) { _, _, _, _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { completion = $0 } }
            return png
        }
        store.update(worktrees: requests(["login"]), isActive: true)
        while completion == nil { await Task.yield() }
        store.update(worktrees: requests(["login"]), isActive: false)
        store.update(worktrees: requests(["login"]), isActive: true)
        #expect(calls == 1)
        completion?.resume(returning: png)
        await store.waitUntilIdle()
        #expect(calls == 2)
        #expect(store.images["login"] != nil)
    }

    @Test("@spec LAYOUT-2.80: When a linked worktree has no cached context-based artwork, the application shall wait for a submitted user prompt or existing user-message history before generating, replace legacy artwork once, and keep the generated image stable across later prompts and launches.")
    func waitsForUserContextAndThenKeepsIdentity() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var prompts: [String] = []
        let request = requests(["new-worktree"])[0]
        let store = WorktreeIconStore(directory: directory) { _, prompt, _, _, _ in
            prompts.append(prompt)
            return png
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(prompts.isEmpty)
        store.recordPrompt("   ", for: request)
        await store.waitUntilIdle()
        #expect(prompts.isEmpty)
        store.recordPrompt("Add flight booking search", for: request)
        store.recordPrompt("Make the button blue", for: request)
        await store.waitUntilIdle()
        #expect(prompts == ["Add flight booking search"])
        store.recordPrompt("An unrelated later task", for: request)
        await store.waitUntilIdle()
        #expect(prompts.count == 1)
        let restored = WorktreeIconStore(directory: directory) { _, _, _, _, _ in
            Issue.record("Should reuse the stable image")
            return png
        }
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        #expect(restored.images[request.path] != nil)
    }

    @Test("User context and artwork are isolated between same-named worktrees")
    func sameNamesDoNotShareContext() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let first = WorktreeArtworkRequest(path: "/project-one/fix", name: "fix", firstPaneSessionName: nil)
        let second = WorktreeArtworkRequest(path: "/project-two/fix", name: "fix", firstPaneSessionName: nil)
        var prompts: [String] = []
        let store = WorktreeIconStore(directory: directory) { _, prompt, _, _, _ in
            prompts.append(prompt)
            return png
        }
        store.update(worktrees: [first, second], isActive: true)
        store.recordPrompt("Fix calendar reminders", for: first)
        await store.waitUntilIdle()
        #expect(store.images[first.path] != nil)
        #expect(store.images[second.path] == nil)
        store.recordPrompt("Fix photo imports", for: second)
        await store.waitUntilIdle()
        #expect(prompts == ["Fix calendar reminders", "Fix photo imports"])
    }

    @Test("A submitted prompt takes precedence over an in-flight history read")
    func livePromptWinsOverHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        var completion: CheckedContinuation<String?, Never>?
        var prompts: [String] = []
        let request = requests(["existing"])[0]
        let store = WorktreeIconStore(directory: directory, history: { _ in
            await withCheckedContinuation { completion = $0 }
        }) { _, prompt, _, _, _ in
            prompts.append(prompt)
            return png
        }
        store.update(worktrees: [request], isActive: true)
        while completion == nil { await Task.yield() }
        store.recordPrompt("Build a calendar", for: request)
        completion?.resume(returning: "Old task about photos")
        await store.waitUntilIdle()
        #expect(prompts == ["Build a calendar"])
    }

    @Test("Legacy artwork remains visible until a user-context replacement is ready")
    func upgradesLegacyArtworkOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = directory.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let png = try imageData()
        let request = requests(["old-art"])[0]
        let key = SHA256.hash(data: Data(request.name.utf8)).map { String(format: "%02x", $0) }.joined()
        try png.write(to: legacy.appendingPathComponent(key).appendingPathExtension("png"))
        var calls = 0
        let store = WorktreeIconStore(directory: directory, legacyDirectory: legacy) { _, _, _, _, _ in
            calls += 1
            return png
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(store.images[request.path] != nil)
        #expect(calls == 0)
        store.recordPrompt("Design a mountain trail map", for: request)
        await store.waitUntilIdle()
        #expect(calls == 1)
    }

    @Test("Disabling artwork cancels generation and style changes use separate caches")
    func preferenceChangesControlGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let request = requests(["styled"])[0]
        var styles: [WorktreeArtworkStyle] = []
        var completion: CheckedContinuation<Data, Never>?
        let store = WorktreeIconStore(directory: directory) { _, _, style, _, _ in
            styles.append(style)
            if styles.count == 1 { return await withCheckedContinuation { completion = $0 } }
            return png
        }
        store.update(worktrees: [request], isActive: true)
        store.recordPrompt("Build a calendar", for: request)
        while completion == nil { await Task.yield() }
        store.configure(enabled: false, style: .illustration)
        completion?.resume(returning: png)
        await store.waitUntilIdle()
        #expect(store.images.isEmpty)
        store.configure(enabled: true, style: .sketch)
        await store.waitUntilIdle()
        #expect(styles == [.illustration, .sketch])
        #expect(store.images[request.path] != nil)
        store.configure(enabled: true, style: .animation)
        await store.waitUntilIdle()
        store.configure(enabled: true, style: .sketch)
        await store.waitUntilIdle()
        #expect(styles == [.illustration, .sketch, .animation])
    }

    @Test("A newly registered first-pane session can supply history after an earlier empty lookup")
    func sessionRegistrationRetriesMissingHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let request = requests(["late-session"])[0]
        var savedPrompt: String?
        var prompts: [String] = []
        let store = WorktreeIconStore(directory: directory, history: { _ in savedPrompt }) { _, prompt, _, _, _ in
            prompts.append(prompt)
            return png
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(prompts.isEmpty)
        savedPrompt = "Build a weather forecast"
        store.retryHistory(for: request)
        await store.waitUntilIdle()
        #expect(prompts == ["Build a weather forecast"])
    }

    @Test("@spec LAYOUT-2.82: When the user chooses Regenerate Background Image for an enabled linked worktree, the application shall refresh its user context, generate a replacement in the selected style, retain the current image until success, and cache the replacement.")
    func regenerationUsesLatestHistoryAndKeepsOldImageUntilSuccess() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData(color: .red)
        let replacement = try imageData(color: .blue)
        #expect(NSBitmapImageRep(data: replacement)?.colorAt(x: 0, y: 0)?.blueComponent == 1)
        let request = requests(["regenerate"])[0]
        var history = "Build a calendar"
        var contexts: [String] = []
        var styles: [WorktreeArtworkStyle] = []
        var completion: CheckedContinuation<Data, Never>?
        let store = WorktreeIconStore(directory: directory, history: { _ in history }) { _, context, style, _, _ in
            contexts.append(context)
            styles.append(style)
            if contexts.count == 2 { return await withCheckedContinuation { completion = $0 } }
            return png
        }
        store.configure(enabled: true, style: .sketch)
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        let old = try #require(store.images[request.path])
        history = "Build a telescope dashboard"
        store.regenerate(request)
        #expect(store.regeneratingPaths.contains(request.path))
        while completion == nil { await Task.yield() }
        #expect(store.images[request.path] === old)
        #expect(contexts == ["Build a calendar", "Build a telescope dashboard"])
        completion?.resume(returning: replacement)
        await store.waitUntilIdle()
        #expect(!store.regeneratingPaths.contains(request.path))
        #expect(store.images[request.path] !== old)
        #expect(styles == [.sketch, .sketch])
        let cachedFiles = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("sketch"), includingPropertiesForKeys: nil)
        #expect(try Data(contentsOf: #require(cachedFiles.first { $0.pathExtension == "png" })) == replacement)
        let restored = WorktreeIconStore(directory: directory) { _, _, _, _, _ in
            Issue.record("The regenerated image should be cached")
            return png
        }
        restored.configure(enabled: true, style: .sketch)
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        let restoredData = try #require(restored.images[request.path]?.tiffRepresentation)
        let restoredBitmap = try #require(NSBitmapImageRep(data: restoredData))
        #expect(restoredBitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)?.blueComponent == 1)
    }

    @Test("Regeneration uses the latest captured prompt when history is unavailable and preserves artwork on failure")
    func regenerationUsesLatestPromptAndCanRetryFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let request = requests(["retry"])[0]
        var contexts: [String] = []
        let store = WorktreeIconStore(directory: directory) { _, context, _, _, _ in
            contexts.append(context)
            if contexts.count == 2 { throw TestFailure.rejected }
            return png
        }
        store.update(worktrees: [request], isActive: true)
        store.recordPrompt("Old calendar task", for: request)
        await store.waitUntilIdle()
        let old = try #require(store.images[request.path])
        store.recordPrompt("New telescope task", for: request)
        await store.waitUntilIdle()
        #expect(contexts.count == 1)
        store.regenerate(request)
        #expect(store.regeneratingPaths.contains(request.path))
        await store.waitUntilIdle()
        #expect(contexts == ["Old calendar task", "New telescope task"])
        #expect(store.regeneratingPaths.isEmpty)
        #expect(store.images[request.path] === old)
        store.regenerate(request)
        #expect(store.regeneratingPaths.contains(request.path))
        await store.waitUntilIdle()
        #expect(contexts.last == "New telescope task")
        #expect(contexts.count == 3)
        #expect(!store.regeneratingPaths.contains(request.path))
        #expect(store.images[request.path] !== old)
    }

    @Test("A regeneration requested during generation discards the superseded result")
    func regenerationDiscardsInFlightResult() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let request = requests(["in-flight"])[0]
        var contexts: [String] = []
        var history = "First task"
        var completion: CheckedContinuation<Data, Never>?
        var storeImageCheck: (() -> Bool)?
        let store = WorktreeIconStore(directory: directory, history: { _ in history }) { _, context, _, _, _ in
            contexts.append(context)
            if contexts.count == 1 { return await withCheckedContinuation { completion = $0 } }
            #expect(storeImageCheck?() == true)
            return png
        }
        storeImageCheck = { store.images[request.path] == nil }
        defer { storeImageCheck = nil }
        store.update(worktrees: [request], isActive: true)
        while completion == nil { await Task.yield() }
        history = "Latest task"
        store.regenerate(request)
        #expect(store.regeneratingPaths.contains(request.path))
        completion?.resume(returning: png)
        await store.waitUntilIdle()
        #expect(contexts == ["First task", "Latest task"])
    }

    @Test("@spec LAYOUT-2.83: When the user requests background regeneration, the application shall immediately mark the artwork pending, blur and dim it across the sidebar and terminal layout, and restore clarity when the request succeeds or cannot complete.")
    func pendingBeginsBeforeHistoryReadAndEndsWithoutContext() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = requests(["pending"])[0]
        var read: CheckedContinuation<String?, Never>?
        let store = WorktreeIconStore(directory: directory, history: { _ in
            await withCheckedContinuation { read = $0 }
        }) { _, _, _, _, _ in
            Issue.record("No user context is available")
            return Data()
        }
        store.update(worktrees: [request], isActive: false)
        store.regenerate(request)
        #expect(store.regeneratingPaths == [request.path])
        store.update(worktrees: [request], isActive: true)
        while read == nil { await Task.yield() }
        #expect(store.regeneratingPaths == [request.path])
        read?.resume(returning: nil)
        await store.waitUntilIdle()
        #expect(store.regeneratingPaths.isEmpty)
    }

    @Test("Pending artwork clears when its worktree is removed or its style changes")
    func pendingClearsWhenRemovedOrStyleChanges() {
        let store = WorktreeIconStore(directory: temporaryDirectory()) { _, _, _, _, _ in Data() }
        let request = requests(["pending"])[0]
        store.update(worktrees: [request], isActive: false)
        store.regenerate(request)
        store.update(worktrees: [], isActive: false)
        #expect(store.regeneratingPaths.isEmpty)
        store.update(worktrees: [request], isActive: false)
        store.regenerate(request)
        store.configure(enabled: true, style: .sketch)
        #expect(store.regeneratingPaths.isEmpty)
    }

    @Test("Manual regeneration varies requests while automatic refreshes preserve the cached artwork")
    func manualRegenerationVariesRequests() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let request = requests(["variation"])[0]
        var variants: [UInt64] = []
        var contexts: [String] = []
        var styles: [WorktreeArtworkStyle] = []
        let store = WorktreeIconStore(directory: directory, history: { _ in "Plan a garden" }) { _, context, style, variation, _ in
            variants.append(variation)
            contexts.append(context)
            styles.append(style)
            return png
        }
        store.configure(enabled: true, style: .sketch)
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(variants == [0])
        for _ in 0..<3 {
            store.regenerate(request)
            await store.waitUntilIdle()
        }
        #expect(Set(variants).count == 4)
        let identities = variants.map { WorktreeArtworkIdentity(name: request.name, variation: $0) }
        for (old, new) in zip(identities, identities.dropFirst()) {
            #expect(old.palette != new.palette)
            #expect(old.composition != new.composition)
        }
        #expect(contexts == Array(repeating: "Plan a garden", count: 4))
        #expect(styles == Array(repeating: .sketch, count: 4))
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(variants.count == 4)
        let last = try #require(identities.last)
        let restored = WorktreeIconStore(directory: directory, history: { _ in "Plan a garden" }) { _, _, _, variation, _ in
            let identity = WorktreeArtworkIdentity(name: request.name, variation: variation)
            #expect(identity.palette != last.palette)
            #expect(identity.composition != last.composition)
            variants.append(variation)
            return png
        }
        restored.configure(enabled: true, style: .sketch)
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        #expect(variants.count == 4)
        restored.regenerate(request)
        await restored.waitUntilIdle()
        #expect(variants.count == 5)
    }

    @Test("@spec LAYOUT-2.86: When Ghostty theme colors change, the application shall generate matching worktree backgrounds, discard results for the previous theme, and reuse cached images when returning to a theme.")
    func themeChangesCancelGenerationAndReuseCaches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData()
        let dark = WorktreeArtworkTheme(theme: .fallback)
        let light = WorktreeArtworkTheme(theme: GhosttyTheme(
            backgroundRGB: .init(r: 1, g: 1, b: 1), foregroundRGB: .init(r: 0, g: 0, b: 0)))
        let request = requests(["themed"])[0]
        var themes: [WorktreeArtworkTheme?] = []
        var completion: CheckedContinuation<Data, Never>?
        let store = WorktreeIconStore(directory: directory, history: { _ in "Plan a garden" }) { _, _, _, _, theme in
            themes.append(theme)
            if themes.count == 1 { return await withCheckedContinuation { completion = $0 } }
            return png
        }
        store.configure(theme: dark)
        store.update(worktrees: [request], isActive: true)
        while completion == nil { await Task.yield() }
        store.configure(theme: light)
        completion?.resume(returning: png)
        await store.waitUntilIdle()
        #expect(themes == [dark, light])
        let lightImage = try #require(store.images[request.path])
        store.configure(theme: dark)
        #expect(store.images[request.path] === lightImage)
        await store.waitUntilIdle()
        #expect(themes == [dark, light, dark])
        store.configure(theme: light)
        await store.waitUntilIdle()
        #expect(themes.count == 3)
        #expect(store.regeneratingPaths.isEmpty)
        let restored = WorktreeIconStore(directory: directory) { _, _, _, _, _ in
            Issue.record("The selected theme should reuse its cached image")
            return png
        }
        restored.configure(theme: dark)
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        #expect(restored.images[request.path] != nil)
    }

    @Test("Unthemed cached artwork remains visible until a themed replacement succeeds")
    func themeUpgradeKeepsExistingCacheVisible() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try imageData(color: .red)
        let request = requests(["upgrade"])[0]
        let old = WorktreeIconStore(directory: directory, history: { _ in "Plan a garden" }) { _, _, _, _, _ in png }
        old.update(worktrees: [request], isActive: true)
        await old.waitUntilIdle()
        let themed = WorktreeIconStore(directory: directory) { _, _, _, _, _ in
            Issue.record("No task context is available yet")
            return png
        }
        themed.configure(theme: WorktreeArtworkTheme(theme: .fallback))
        themed.update(worktrees: [request], isActive: true)
        await themed.waitUntilIdle()
        #expect(themed.images[request.path] != nil)
    }

    @Test("Earlier themed images remain placeholders while corrected theme prompts generate replacements")
    func earlierThemeCacheIsRefreshedWithoutBlankingArtwork() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = requests(["old-theme"])[0]
        let theme = WorktreeArtworkTheme(theme: .fallback)
        let oldDirectory = directory.appendingPathComponent("illustration").appendingPathComponent(theme.colorCacheKey)
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(request.path.utf8)).map { String(format: "%02x", $0) }.joined()
        try imageData(color: .red).write(to: oldDirectory.appendingPathComponent(key + ".png"))
        let replacement = try imageData(color: .blue)
        var calls = 0
        let store = WorktreeIconStore(directory: directory, history: { _ in "Plan a garden" }) { _, _, _, _, _ in
            calls += 1
            return replacement
        }
        store.configure(theme: theme)
        store.update(worktrees: [request], isActive: true)
        let old = try #require(store.images[request.path])
        await store.waitUntilIdle()
        #expect(calls == 1)
        #expect(store.images[request.path] !== old)
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        #expect(calls == 1)
    }

    private func requests(_ names: [String]) -> [WorktreeArtworkRequest] {
        names.map { WorktreeArtworkRequest(path: $0, name: $0, firstPaneSessionName: nil) }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    private func imageData(color: NSColor = .clear) throws -> Data {
        let context = try #require(CGContext(data: nil, width: 2, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private enum TestFailure: Error { case rejected }
}
