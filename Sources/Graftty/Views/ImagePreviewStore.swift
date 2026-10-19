import AppKit
import Combine
import GrafttyKit

/// Ephemeral, per-pane previews. No terminal rows or persisted history.
@MainActor
final class ImagePreviewStore: ObservableObject {
    static let shared = ImagePreviewStore()
    static let maximumPreviews = 8

    struct Preview: Identifiable {
        let id = UUID()
        let createdAt = Date()
        let createdInstant = ContinuousClock.now
        let files: [FilePreviewFile]
        var filename: String { files.first?.url.lastPathComponent ?? "Preview" }
        var sourceURL: URL? { files.first?.sourceURL }

        init(files: [FilePreviewFile]) {
            precondition(!files.isEmpty)
            self.files = files
        }
    }

    @Published private(set) var previews: [PaneSlotID: Preview] = [:]
    struct RequestGeneration: Equatable {
        let sequence: UInt64
    }
    private var nextSequence: UInt64 = 0
    private var generations: [PaneSlotID: RequestGeneration] = [:]
    private var order: [PaneSlotID] = []
    private var worktreePaths: [PaneSlotID: String] = [:]

    func beginRequest(for pane: PaneSlotID) -> RequestGeneration {
        nextSequence += 1
        let generation = RequestGeneration(sequence: nextSequence)
        generations[pane] = generation
        return generation
    }

    func isCurrent(_ generation: RequestGeneration, for pane: PaneSlotID) -> Bool { generations[pane] == generation }

    func finishRequest(_ generation: RequestGeneration, for pane: PaneSlotID) {
        if isCurrent(generation, for: pane) { generations.removeValue(forKey: pane) }
    }

    func present(files: [FilePreviewFile], for pane: PaneSlotID) {
        present(Preview(files: files), for: pane)
    }

    func present(_ preview: Preview, for pane: PaneSlotID, worktreePath: String? = nil) {
        order.removeAll { $0 == pane }
        if order.count >= Self.maximumPreviews, let oldest = order.first { dismiss(oldest) }
        worktreePaths[pane] = worktreePath
        previews[pane] = preview
        order.append(pane)
    }

    func previews(forWorktreePath path: String) -> [PaneSlotID: Preview] {
        previews.filter { worktreePaths[$0.key] == path }
    }

    func dismiss(previewID: UUID) {
        for pane in previews.filter({ $0.value.id == previewID }).map(\.key) { dismiss(pane) }
    }

    func dismiss(_ pane: PaneSlotID) {
        generations.removeValue(forKey: pane)
        worktreePaths.removeValue(forKey: pane)
        previews.removeValue(forKey: pane)
        order.removeAll { $0 == pane }
    }
}

enum ImagePreviewLayout {
    static func visiblePane(tree: SplitTree, focused: PaneSlotID?) -> PaneSlotID? {
        if let zoomed = tree.zoomed, tree.containsLeaf(zoomed) { return zoomed }
        if let focused, tree.containsLeaf(focused) { return focused }
        return tree.root?.allLeaves.first
    }

    static func trayHeight(paneHeight: CGFloat) -> CGFloat { max(0, min(360, paneHeight * 0.45)) }
}
