import AppKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree SVG atlas")
@MainActor
struct WorktreeSVGMapTests {
    @Test func reviewContextSelectsCodeReviewIllustration() throws {
        for task in ["Review the current changes", "Inspect the implementation", "Audit the code"] {
            let data = try WorktreeSVGMap.generate(.init(
                rows: [.init(path: "/project/review", name: "code-review", height: 104, context: task)],
                project: .init(path: "/project", avatar: nil), style: .illustration,
                theme: nil, preservedPaths: []))
            #expect(WorktreeSVGMap.districts(in: data)?["/project/review"]?.motif == .forge)
            #expect(String(decoding: data, as: UTF8.self).contains("data-task=\"code-review\""))
        }
    }

    @Test func previewDoesNotImplyCodeReview() throws {
        let data = try WorktreeSVGMap.generate(.init(
            rows: [.init(path: "/project/browser", name: "image-browser", height: 104, context: "Add a preview pane")],
            project: .init(path: "/project", avatar: nil), style: .illustration,
            theme: nil, preservedPaths: []))
        #expect(WorktreeSVGMap.districts(in: data)?["/project/browser"]?.motif == .garden)
        #expect(String(decoding: data, as: UTF8.self).contains("data-task=\"image-browser\""))
    }

    @Test("@spec LAYOUT-2.118: When generating a worktree map, the application shall create a contiguous SVG world with task-grounded districts, distinct regional colors and filled landmarks, and shared routes across row boundaries.")
    func contiguousMapHasGroundedDistinctDistricts() throws {
        let rows = [WorktreeMapRow(path: "a", name: "notifications", height: 104, context: "Notify people when reviews finish"),
                    WorktreeMapRow(path: "b", name: "search", height: 160, context: "Improve search results"),
                    WorktreeMapRow(path: "c", name: "scroll", height: 80, context: "Scroll through history")]
        let input = WorktreeMapGeneration(rows: rows, project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: [])
        let data = try WorktreeSVGMap.generate(input)
        let source = String(decoding: data, as: UTF8.self)
        #expect(source.contains("<svg"))
        #expect(source.contains("id=\"shared-route\""))
        #expect(!source.contains("<image"))
        let districts = try #require(WorktreeSVGMap.districts(in: data))
        #expect(districts["a"]?.motif == .beacon)
        #expect(districts["b"]?.motif == .observatory)
        #expect(districts["c"]?.motif == .canal)
        #expect(Set(districts.values.map(\.palette)).count == 3)
        let image = try #require(NSImage(data: data))
        #expect(image.size == NSSize(width: 320, height: 344))
        #expect(WorktreeMapRaster.hasCompleteCanvas(image))
        let slices = try WorktreeMapRaster.slices(image, rows: rows)
        #expect(slices["b"]?.size.height == 160)
        var rect = CGRect(origin: .zero, size: image.size)
        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        let before = try #require(bitmap.colorAt(x: 214, y: 103)?.usingColorSpace(.deviceRGB))
        let after = try #require(bitmap.colorAt(x: 214, y: 104)?.usingColorSpace(.deviceRGB))
        #expect(abs(before.redComponent - after.redComponent) < 0.06)
    }

    @Test("@spec LAYOUT-2.119: When an SVG map is reordered or regenerated, the application shall preserve unchanged district identities, rebuild shared connections, and change only explicitly replaced or newly contextualized districts.")
    func reorderAndRegenerateRetainDistrictIdentity() throws {
        let rows = [WorktreeMapRow(path: "a", name: "search", height: 80, context: "Search"),
                    WorktreeMapRow(path: "b", name: "security", height: 104, context: "Secure access")]
        var input = WorktreeMapGeneration(rows: rows, project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: [])
        let first = try WorktreeSVGMap.generate(input)
        input = WorktreeMapGeneration(rows: rows.reversed(), project: input.project, style: input.style,
            theme: nil, preservedPaths: ["a", "b"], previousSVG: first)
        let reordered = try WorktreeSVGMap.generate(input)
        #expect(WorktreeSVGMap.districts(in: first) == WorktreeSVGMap.districts(in: reordered))
        #expect(first != reordered)
        input = WorktreeMapGeneration(rows: rows, project: input.project, style: input.style,
            theme: nil, preservedPaths: ["b"], previousSVG: reordered)
        let replaced = try WorktreeSVGMap.generate(input)
        #expect(WorktreeSVGMap.districts(in: replaced)?["b"] == WorktreeSVGMap.districts(in: first)?["b"])
        #expect(WorktreeSVGMap.districts(in: replaced)?["a"] != WorktreeSVGMap.districts(in: first)?["a"])
    }

    @Test("@spec LAYOUT-2.122: When worktrees share a task category, the application shall allocate different landmark silhouettes while unused variants remain, preserving existing identities during cache upgrades and reordering.")
    func relatedTasksHaveDifferentSilhouettes() throws {
        for motif in WorktreeSVGMap.Motif.allCases {
            let rows = (0..<3).map { WorktreeMapRow(path: "\($0)", name: "notifications", height: 104, context: nil) }
            let old = Dictionary(uniqueKeysWithValues: rows.enumerated().map { i, row in
                (row.path, WorktreeSVGMap.District(motif: motif, palette: i, variation: UInt64(i)))
            })
            let json = try JSONEncoder().encode(old).base64EncodedString()
            let legacy = Data("<svg ><metadata id=\"graftty-districts\">\(json)</metadata></svg>".utf8)
            let input = WorktreeMapGeneration(rows: rows, project: .init(path: "/project", avatar: nil),
                style: .illustration, theme: nil, preservedPaths: [], previousSVG: legacy)
            let data = try WorktreeSVGMap.generate(input)
            let migrated = try #require(WorktreeSVGMap.districts(in: data))
            #expect(Set(migrated.values.compactMap(\.variant)).count == 3)
            for row in rows {
                #expect(migrated[row.path]?.palette == old[row.path]?.palette)
                #expect(migrated[row.path]?.variation == old[row.path]?.variation)
                #expect(migrated[row.path]?.motif == motif)
            }
            #expect(Set(migrated.values.map { WorktreeSVGMap.landmark($0.motif, variant: $0.variant ?? 0) }).count == 3)
            #expect(NSImage(data: data) != nil)
            let reordered = try WorktreeSVGMap.generate(.init(rows: rows.reversed(), project: input.project,
                style: input.style, theme: nil, preservedPaths: Set(rows.map(\.path)), previousSVG: data))
            #expect(WorktreeSVGMap.districts(in: reordered) == migrated)
        }
    }

    @Test("@spec LAYOUT-2.123: While SVG map artwork extends above or below the worktrees, the application shall use straight continuous routes without repeated bends or decorative tiles.")
    func decorativeExtensionsHaveNoRepeatingBends() throws {
        let rows = [WorktreeMapRow(path: "header", name: "header", height: 128, context: nil, isConnector: true),
                    WorktreeMapRow(path: "footer", name: "footer", height: 96, context: nil, isConnector: true)]
        let data = try WorktreeSVGMap.generate(.init(rows: rows, project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: []))
        let image = try #require(NSImage(data: data))
        var rect = CGRect(origin: .zero, size: image.size)
        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        for x in [140, 208, 212, 248, 262] {
            let first = try #require(bitmap.colorAt(x: x, y: 10)?.usingColorSpace(.deviceRGB))
            for y in [30, 60, 100, 140, 180, 210] {
                let next = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                #expect(abs(first.redComponent - next.redComponent) < 0.01)
            }
        }
    }

    @Test func userTaskOverridesOpaqueNameAndXMLIsNotInjected() throws {
        let input = WorktreeMapGeneration(rows: [.init(path: "<script>", name: "fix-search", height: 80,
            context: "Add authentication and permissions <image href='https://example.com'/>")],
            project: .init(path: "/project", avatar: nil), style: .sketch, theme: nil, preservedPaths: [])
        let data = try WorktreeSVGMap.generate(input)
        #expect(WorktreeSVGMap.districts(in: data)?["<script>"]?.motif == .gate)
        #expect(!String(decoding: data, as: UTF8.self).contains("<script>"))
        #expect(!String(decoding: data, as: UTF8.self).contains("example.com"))
    }

    @Test func regenerationKeepsColorsDistinctForSimilarTasks() throws {
        let rows = (0..<4).map { WorktreeMapRow(path: "\($0)", name: "notifications", height: 80, context: "Notify") }
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let original = try WorktreeSVGMap.generate(.init(rows: rows, project: project, style: .illustration, theme: nil, preservedPaths: []))
        let replaced = try WorktreeSVGMap.generate(.init(rows: rows, project: project, style: .illustration,
            theme: nil, preservedPaths: ["1", "2", "3"], previousSVG: original))
        let districts = try #require(WorktreeSVGMap.districts(in: replaced))
        #expect(Set(districts.values.map(\.palette)).count == 4)
    }

    @Test func similarNamesChooseGroundedVariantsAndRegenerationAvoidsHiddenNeighbors() throws {
        let rows = [WorktreeMapRow(path: "a", name: "claude-notifications", height: 104, context: "Needs attention"),
                    WorktreeMapRow(path: "b", name: "push-notifications", height: 104, context: "Broadcast updates")]
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let original = try WorktreeSVGMap.generate(.init(rows: rows, project: project, style: .illustration,
            theme: nil, preservedPaths: []))
        let old = try #require(WorktreeSVGMap.districts(in: original))
        #expect(old["a"]?.variant == 1)
        #expect(old["b"]?.variant == 2)
        let changed = try WorktreeSVGMap.generate(.init(rows: [rows[0]], project: project, style: .illustration,
            theme: nil, preservedPaths: [], previousSVG: original, registeredPaths: ["a", "b"]))
        let updated = try #require(WorktreeSVGMap.districts(in: changed))
        #expect(updated["a"]?.variant == 0)
        #expect(updated["b"] == old["b"])
    }

    @Test(arguments: [3, 4, 5]) func legacySVGCacheUpgradesOnceWithoutChangingColors(revision: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "/project", name: "main", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil), isMainCheckout: true)
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil },
            generate: ProjectWorktreeMapGenerator.generate)
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        var saved = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let encodedSVG = try #require(saved["svg"] as? String)
        let originalSVG = try #require(Data(base64Encoded: encodedSVG))
        let original = try #require(WorktreeSVGMap.districts(in: originalSVG))
        var old = original
        if revision == 3 { for path in old.keys { old[path]?.variant = nil } }
        let metadata = try JSONEncoder().encode(old).base64EncodedString()
        saved["svg"] = Data("<svg ><metadata id=\"graftty-districts\">\(metadata)</metadata></svg>".utf8).base64EncodedString()
        saved["regionRevision"] = revision
        try JSONSerialization.data(withJSONObject: saved).write(to: file)
        var calls = 0
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls += 1
            let data = try await ProjectWorktreeMapGenerator.generate(input)
            let upgraded = try #require(WorktreeSVGMap.districts(in: data))
            #expect(upgraded[request.path]?.palette == original[request.path]?.palette)
            #expect(upgraded[request.path]?.variation == original[request.path]?.variation)
            #expect(upgraded[request.path]?.variant != nil)
            if revision >= 4 { #expect(upgraded == original) }
            return data
        }
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        restored.update(worktrees: [request], isActive: true)
        await restored.waitUntilIdle()
        #expect(calls == 1)
        #expect(restored.failures.isEmpty)
    }

    @Test(arguments: [WorktreeSVGMap.Motif.beacon, .garden])
    func regenerationAndFamilyChangesDoNotDuplicateAvailableSilhouettes(oldFamily: WorktreeSVGMap.Motif) throws {
        let old: [String: WorktreeSVGMap.District] = [
            "a": .init(motif: oldFamily, palette: 0, variation: 0, variant: 0),
            "b": .init(motif: .beacon, palette: 1, variation: 1, variant: 1),
            "c": .init(motif: .beacon, palette: 2, variation: 2, variant: 2)]
        let metadata = try JSONEncoder().encode(old).base64EncodedString()
        let previous = Data("<svg ><metadata id=\"graftty-districts\">\(metadata)</metadata></svg>".utf8)
        let data = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "notify", height: 104, context: "Notifications")],
            project: .init(path: "/project", avatar: nil), style: .illustration, theme: nil,
            preservedPaths: [], previousSVG: previous, registeredPaths: ["a", "b", "c"]))
        let updated = try #require(WorktreeSVGMap.districts(in: data))
        #expect(updated["a"]?.motif == .beacon)
        #expect(Set(updated.values.compactMap(\.variant)).count == 3)
    }

    @Test func migrationStillAppliesPendingContextChanges() throws {
        let old = ["a": WorktreeSVGMap.District(motif: .garden, palette: 0, variation: 0)]
        let metadata = try JSONEncoder().encode(old).base64EncodedString()
        let previous = Data("<svg ><metadata id=\"graftty-districts\">\(metadata)</metadata></svg>".utf8)
        let data = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "icons", height: 104, context: "Authentication permissions")],
            project: .init(path: "/project", avatar: nil), style: .illustration, theme: nil,
            preservedPaths: [], previousSVG: previous, changingPaths: ["a"]))
        let updated = try #require(WorktreeSVGMap.districts(in: data))
        #expect(updated["a"]?.motif == .gate)
        #expect(updated["a"]?.variation == 1)
    }

    @Test("@spec LAYOUT-2.124: While an SVG district is displayed, the application shall keep its title band and extended pane terrain free of repeating artwork, place its landmark below the title, and retain a subdued connecting route.")
    func titlesAndExtendedTerrainRemainQuiet() throws {
        let data = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "notifications", height: 240, context: nil)],
            project: .init(path: "/project", avatar: nil), style: .illustration, theme: nil, preservedPaths: []))
        let image = try #require(NSImage(data: data))
        var rect = CGRect(origin: .zero, size: image.size)
        let bitmap = NSBitmapImageRep(cgImage: try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil)))
        func sample(_ x: Int, _ y: Int) throws -> NSColor {
            try #require(bitmap.colorAt(x: x * bitmap.pixelsWide / 320,
                y: y * bitmap.pixelsHigh / 240)?.usingColorSpace(.deviceRGB))
        }
        for y in [14, 22, 30, 100, 130, 160, 200] {
            let ground = try sample(20, y)
            for x in stride(from: 40, through: 198, by: 8) {
                let pixel = try sample(x, y)
                #expect(abs(pixel.redComponent - ground.redComponent) < 0.01)
                #expect(abs(pixel.greenComponent - ground.greenComponent) < 0.01)
                #expect(abs(pixel.blueComponent - ground.blueComponent) < 0.01)
            }
        }
        let ground = try sample(20, 55)
        var landmarkPixels = 0
        for y in 34..<80 {
            for x in 150..<198 {
                let pixel = try sample(x, y)
                if abs(pixel.redComponent - ground.redComponent) > 0.1 { landmarkPixels += 1 }
            }
        }
        #expect(landmarkPixels > 100)
    }

    @Test func taskPurposeSelectsLandmarksInsteadOfGenericCategoryAlone() {
        let examples: [(WorktreeSVGMap.Motif, String, Int)] = [
            (.beacon, "Ask for human approval before proceeding", 1),
            (.beacon, "Deliver updates to a remote device", 2),
            (.archive, "Recover data from a backup", 0),
            (.archive, "Partition storage into separate buckets", 1),
            (.archive, "Encrypt stored secrets", 2),
            (.observatory, "Research which approach to use", 0),
            (.observatory, "Index and catalog project files", 1),
            (.observatory, "Listen for incoming events", 2),
        ]
        for (family, context, expected) in examples {
            for seed in 0..<10 {
                #expect(WorktreeSVGMap.preferredVariant(family, name: "task", context: context, seed: UInt64(seed)) == expected)
            }
        }
    }

    @Test func laterPromptsKeepTheLearnedPlaceUntilExplicitRegeneration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "a", name: "notifications", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil))
        var latest = "Notify when human approval is needed"
        var generations: [[String: WorktreeSVGMap.District]] = []
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in latest }) { input in
            let data = try await ProjectWorktreeMapGenerator.generate(input)
            generations.append(try #require(WorktreeSVGMap.districts(in: data)))
            return data
        }
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        let image = store.images[request.path]
        latest = "Add authentication permissions"
        store.recordPrompt(latest, for: request)
        await store.waitUntilIdle()
        #expect(generations.count == 1)
        #expect(store.images[request.path] === image)
        #expect(generations.first?[request.path]?.motif == .beacon)
        store.regenerate(request)
        await store.waitUntilIdle()
        #expect(generations.count == 2)
        #expect(generations.last?[request.path]?.motif == .gate)
    }

    @Test func updatedPurposeWithinTheSameFamilyUsesItsPreferredLandmark() throws {
        let old = ["a": WorktreeSVGMap.District(motif: .archive, palette: 0, variation: 0, variant: 1)]
        let metadata = try JSONEncoder().encode(old).base64EncodedString()
        let previous = Data("<svg ><metadata id=\"graftty-districts\">\(metadata)</metadata></svg>".utf8)
        let data = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "storage", height: 104,
            context: "Encrypt stored database secrets")], project: .init(path: "/project", avatar: nil),
            style: .illustration, theme: nil, preservedPaths: [], previousSVG: previous, changingPaths: ["a"]))
        #expect(WorktreeSVGMap.districts(in: data)?["a"]?.motif == .archive)
        #expect(WorktreeSVGMap.districts(in: data)?["a"]?.variant == 2)
    }

    @Test func saturatedCatalogStillVisiblyRegeneratesWithoutLosingIdentity() throws {
        let rows = (0..<11).map { WorktreeMapRow(path: "\($0)", name: "notify", height: 104, context: nil) }
        let old = Dictionary(uniqueKeysWithValues: rows.enumerated().map { i, row in
            (row.path, WorktreeSVGMap.District(motif: i < 3 ? .beacon : .garden, palette: i,
                variation: 0, variant: i % 3))
        })
        let metadata = try JSONEncoder().encode(old).base64EncodedString()
        let previous = Data("<svg ><metadata id=\"graftty-districts\">\(metadata)</metadata></svg>".utf8)
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let first = try WorktreeSVGMap.generate(.init(rows: rows, project: project, style: .illustration,
            theme: nil, preservedPaths: Set(rows.map(\.path)), previousSVG: previous))
        let next = try WorktreeSVGMap.generate(.init(rows: rows, project: project, style: .illustration,
            theme: nil, preservedPaths: Set(rows.dropFirst().map(\.path)), previousSVG: first))
        let current = try #require(WorktreeSVGMap.districts(in: next))
        #expect(current["0"]?.palette == old["0"]?.palette)
        #expect(current["0"]?.variant == old["0"]?.variant)
        #expect(try WorktreeMapRaster.png(#require(NSImage(data: first))) != WorktreeMapRaster.png(#require(NSImage(data: next))))
    }

    @Test func addingPanesDoesNotMoveOrScaleTheLandmark() throws {
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let small = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "icons", height: 80, context: nil)],
            project: project, style: .illustration, theme: nil, preservedPaths: []))
        let tall = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "icons", height: 240, context: nil)],
            project: project, style: .illustration, theme: nil, preservedPaths: ["a"], previousSVG: small))
        func pixels(_ data: Data) throws -> [Double] {
            let image = try #require(NSImage(data: data))
            var rect = CGRect(origin: .zero, size: image.size)
            let cg = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cg)
            let scale = CGFloat(cg.width) / image.size.width
            var result: [Double] = []
            for y in 34..<70 {
                for x in 145..<198 {
                    let color = try #require(bitmap.colorAt(x: Int(CGFloat(x) * scale),
                        y: Int(CGFloat(y) * scale))?.usingColorSpace(.deviceRGB))
                    result += [color.redComponent, color.greenComponent, color.blueComponent]
                }
            }
            return result
        }
        let before = try pixels(small), after = try pixels(tall)
        // Native SVG rasterization can round color channels between canvas sizes.
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 0.01 })
    }

    @Test func allProjectMediaHaveDistinctRenderedTreatments() throws {
        var rendered = Set<Data>()
        for medium in ProjectMapStyle.allCases {
            let data = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "search", height: 104, context: "search")],
                project: .init(path: "/project", avatar: nil, mapStyle: medium), style: .illustration, theme: nil, preservedPaths: []))
            rendered.insert(try WorktreeMapRaster.png(#require(NSImage(data: data))))
        }
        #expect(rendered.count == ProjectMapStyle.allCases.count)
    }

    @Test func exhaustedPaletteRetainsCurrentColorRatherThanDuplicatingANeighbor() throws {
        var rows = (0..<10).map { (id: Int) in WorktreeMapRow(path: "\(id)", name: "notifications", height: 80, context: nil, regionID: id) }
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        func generate(_ previous: Data?, preserving paths: Set<String>) throws -> Data {
            try WorktreeSVGMap.generate(.init(rows: rows, project: project, style: .illustration,
                theme: nil, preservedPaths: paths, previousSVG: previous))
        }
        let initial = try generate(nil, preserving: [])
        let varied = try generate(initial, preserving: Set(rows.dropFirst().map(\.path)))
        rows.append(.init(path: "10", name: "notifications", height: 80, context: nil, regionID: 10))
        let expanded = try generate(varied, preserving: Set(rows.dropLast().map(\.path)))
        let result = try generate(expanded, preserving: Set(rows.dropFirst().map(\.path)))
        let districts = try #require(WorktreeSVGMap.districts(in: result))
        #expect(Set(districts.values.map(\.palette)).count == 11)
        #expect(districts["0"]?.palette == WorktreeSVGMap.districts(in: expanded)?["0"]?.palette)
    }

    @Test("@spec LAYOUT-2.121: While an SVG map appears in a narrow sidebar, the application shall retain its connected route through the full height of every worktree and its pane rows.")
    func narrowTallRowsKeepTheirRouteVisible() throws {
        let data = try WorktreeSVGMap.generate(.init(rows: [.init(path: "a", name: "notifications", height: 240, context: nil)],
            project: .init(path: "/project", avatar: nil), style: .illustration, theme: nil, preservedPaths: []))
        let image = WorktreeSVGMap.preview(try #require(NSImage(data: data)))
        let renderer = ImageRenderer(content: WorktreeArtworkBackground(image: image,
            backgroundColor: .black, selectionColor: .clear, groupsText: true).frame(width: 220, height: 240))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        for y in [20, 90, 150, 200, 230] {
            let colors = try (203..<219).map { x in
                try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)).redComponent
            }
            #expect(try #require(colors.max()) - #require(colors.min()) > 0.02)
            #expect(try #require(colors.max()) - #require(colors.min()) < 0.12)
        }
    }

    @Test("@spec LAYOUT-2.120: When the Ghostty foreground changes, the application shall regenerate SVG map ink even when the background color is unchanged.")
    func foregroundChangeUpdatesSVGInk() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = WorktreeArtworkRequest(path: "/project", name: "main", firstPaneSessionName: nil,
            project: .init(path: "/project", avatar: nil), isMainCheckout: true)
        var calls = 0
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            calls += 1
            return try await ProjectWorktreeMapGenerator.generate(input)
        }
        store.configure(theme: .init(theme: GhosttyTheme(backgroundRGB: .init(r: 0.1, g: 0.1, b: 0.1), foregroundRGB: .init(r: 1, g: 1, b: 1))))
        store.update(worktrees: [request], isActive: true)
        await store.waitUntilIdle()
        store.configure(theme: .init(theme: GhosttyTheme(backgroundRGB: .init(r: 0.1, g: 0.1, b: 0.1), foregroundRGB: .init(r: 0.8, g: 0.6, b: 0.5))))
        await store.waitUntilIdle()
        #expect(calls == 2)
        #expect(store.failures.isEmpty)
    }

    @Test func productionStoreRestoresSVGAndPreservesDistrictsThroughReordering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let project = ProjectArtworkSource(path: "/project", avatar: nil)
        let requests = [WorktreeArtworkRequest(path: "a", name: "notifications", firstPaneSessionName: nil, project: project),
                        WorktreeArtworkRequest(path: "b", name: "search", firstPaneSessionName: nil, project: project)]
        let store = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { $0.name },
            generate: ProjectWorktreeMapGenerator.generate)
        store.update(worktrees: requests, isActive: true)
        await store.waitUntilIdle()
        #expect(store.failures.isEmpty)
        let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "svg" })
        let original = try Data(contentsOf: file)
        var generationCalls = 0
        let restored = ProjectWorktreeMapStore(directory: directory, debounce: .zero, history: { _ in nil }) { input in
            generationCalls += 1
            #expect(input.previousSVG != nil)
            return try await ProjectWorktreeMapGenerator.generate(input)
        }
        restored.update(worktrees: requests, isActive: true)
        await restored.waitUntilIdle()
        #expect(generationCalls == 0)
        #expect(restored.images.count == 2)
        #expect(restored.images.values.allSatisfy { ($0 as? WorktreeSVGMap.Preview)?.territoryColor != nil })
        restored.update(worktrees: requests.reversed(), isActive: true)
        await restored.waitUntilIdle()
        #expect(generationCalls == 1)
        #expect(WorktreeSVGMap.districts(in: try Data(contentsOf: file)) == WorktreeSVGMap.districts(in: original))
        #expect(restored.failures.isEmpty)
    }
}
