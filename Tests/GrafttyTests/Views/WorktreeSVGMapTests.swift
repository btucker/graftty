import AppKit
import SwiftUI
import Testing
@testable import Graftty

@Suite("Worktree SVG atlas")
@MainActor
struct WorktreeSVGMapTests {
    @Test("@spec LAYOUT-2.118: When generating a worktree map, the application shall create a contiguous SVG world with task-grounded districts, distinct regional colors and patterns, and shared routes across row boundaries.")
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
            #expect(try #require(colors.max()) - #require(colors.min()) > 0.1)
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
        #expect(restored.images.values.allSatisfy { $0 is WorktreeSVGMap.Preview })
        restored.update(worktrees: requests.reversed(), isActive: true)
        await restored.waitUntilIdle()
        #expect(generationCalls == 1)
        #expect(WorktreeSVGMap.districts(in: try Data(contentsOf: file)) == WorktreeSVGMap.districts(in: original))
        #expect(restored.failures.isEmpty)
    }
}
