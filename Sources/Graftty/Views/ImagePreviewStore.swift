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
        let image: CGImage
        let filename: String
        let sourceURL: URL?

        init(image: CGImage, filename: String, sourceURL: URL? = nil) {
            self.image = image
            self.filename = filename
            self.sourceURL = sourceURL
        }
    }

    @Published private(set) var previews: [PaneSlotID: Preview] = [:]
    struct RequestGeneration: Equatable {
        let sequence: UInt64
    }
    private var nextSequence: UInt64 = 0
    private var generations: [PaneSlotID: RequestGeneration] = [:]
    private var order: [PaneSlotID] = []

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

    func present(_ image: CGImage, filename: String, sourceURL: URL? = nil, for pane: PaneSlotID) {
        order.removeAll { $0 == pane }
        if order.count >= Self.maximumPreviews, let oldest = order.first { dismiss(oldest) }
        previews[pane] = Preview(image: image, filename: filename, sourceURL: sourceURL)
        order.append(pane)
    }

    func dismiss(_ pane: PaneSlotID) {
        generations.removeValue(forKey: pane)
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
    static func clampZoom(_ zoom: CGFloat) -> CGFloat { zoom.isFinite ? min(8, max(1, zoom)) : 1 }
    static func fit(image: CGSize, viewport: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = max(0, min(viewport.width / image.width, viewport.height / image.height))
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
