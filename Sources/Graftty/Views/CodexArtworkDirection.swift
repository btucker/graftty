import CryptoKit
import Foundation

/// Independent visual choices give even closely related tasks different identities.
/// These stay stable until the user explicitly requests another interpretation.
struct CodexArtworkDirection: Hashable {
    let subjectDirection: String
    let silhouette: String
    let composition: String
    let paletteIndex: Int
    private let renderingIndex: Int

    init(name: String, variation: UInt64) {
        let digest = Array(SHA256.hash(data: Data(name.utf8)))
        func pick(_ choices: [String], byte: Int) -> String {
            choices[(Int(digest[byte]) + Int(variation % UInt64(choices.count))) % choices.count]
        }
        subjectDirection = pick([
            "a distinctive animal whose behavior embodies the task, with one task-specific physical detail",
            "an ingenious handmade mechanism performing the task's main action",
            "a botanical specimen whose unusual growth or structure embodies the task",
            "an exaggerated everyday object transformed to express the user's intended result",
            "a vehicle or vessel physically carrying out the task's central idea",
            "a musical or scientific instrument that embodies the task's feedback or transformation",
            "a miniature architectural structure shaped around the task's purpose",
            "a sculptural natural formation with one surprising feature related to the task",
        ], byte: 3)
        silhouette = pick([
            "a tall narrow silhouette with one oversized feature",
            "a broad sweeping crescent silhouette",
            "a compact angular silhouette with a clearly stepped outline",
            "a round silhouette with one bold off-center opening",
            "a sharply pointed triangular silhouette",
            "an asymmetric branching silhouette with only a few large branches",
            "a long curved ribbon silhouette with a single large loop",
            "a chunky stacked silhouette with contrasting large and small masses",
        ], byte: 4)
        composition = pick([
            "Extreme close crop from the right edge; one unmistakable feature dominates the center-right",
            "An oversized side profile spanning the right two-thirds, with a strong horizontal gesture",
            "A sweeping diagonal from the center toward the top-right corner",
            "A dramatic overhead view, with the large subject filling the center-right",
            "A low-angle close-up with a tall subject rising through the right half",
            "A bold frontal view with the subject straddling the center and right third",
            "A three-quarter view with strong foreshortening projecting toward the viewer on the right",
            "A tightly cropped detail whose curved outline wraps around the right edge",
        ], byte: 5)
        paletteIndex = Int(digest[1])
        renderingIndex = (Int(digest[6]) + Int(variation % 4)) % 4
    }

    func rendering(style: WorktreeArtworkStyle) -> String {
        let choices: [String]
        switch style {
        case .illustration:
            choices = ["Bold cut-paper illustration with large flat color shapes",
                       "Graphic woodcut illustration with broad carved marks",
                       "Hand-painted gouache illustration with broad opaque brushwork",
                       "Geometric screenprint illustration with crisp overlapping color planes"]
        case .animation:
            choices = ["A clay stop-motion film still with chunky sculpted forms",
                       "A felt-puppet animation still with simple rounded forms",
                       "A stylized 3D animation still with smooth glossy forms",
                       "A hand-painted animated-film still with exaggerated shapes"]
        case .sketch:
            choices = ["A bold charcoal sketch with large gestural strokes and a strong color accent",
                       "An ink sketch with a strong contour and selective colored crosshatching",
                       "A colored-pencil sketch with chunky strokes and emphatic color masses",
                       "A brush-ink sketch with broad expressive marks and a single color wash"]
        }
        return choices[renderingIndex]
    }
}
