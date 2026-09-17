import CryptoKit
import Foundation

/// Stable visual choices keep a worktree recognizable even when its name is opaque.
struct WorktreeArtworkIdentity: Hashable {
    var subject: String
    let palette: String
    let composition: String
    private let fallbackSubject: String
    private let backgroundConcept: String?

    init(name: String, variation: UInt64 = 0, theme: WorktreeArtworkTheme? = nil, project: ProjectArtworkDirection? = nil) {
        let digest = Array(SHA256.hash(data: Data(name.utf8)))
        let subjects = [
            "fox", "octopus", "kingfisher", "sunflower", "chameleon", "toucan", "lantern", "compass",
            "telescope", "sailboat", "cactus", "crystal", "origami crane", "flamingo", "teapot", "seashell",
            "mushroom", "hot air balloon", "beetle", "antique key", "lighthouse", "lemon", "jellyfish", "red panda",
            "dragon", "butterfly", "pineapple", "hummingbird", "violin", "ram", "seahorse", "ringing bell",
        ]
        let palettes = [
            "scarlet red with ivory accents", "cobalt blue with copper accents",
            "emerald green with gold accents", "tangerine orange with navy accents",
            "violet with lemon yellow accents", "hot pink with charcoal accents",
            "turquoise with coral accents", "golden yellow with black accents",
            "lime green with deep purple accents", "burgundy with rose gold accents",
            "ice blue with midnight blue accents", "cream with burnt orange accents",
            "lavender with mint accents", "copper with petrol blue accents",
            "coral pink with plum accents", "white with electric blue accents",
        ]
        let compositions = [
            "Close-up side view, subject on the right",
            "Close-up front view, subject on the right",
            "Diagonal close-up, subject on the right",
            "Close-up viewed from above, subject on the right",
        ]
        subject = project?.subject(name: name, variation: variation) ?? subjects[(Int(digest[0]) + Int(variation % UInt64(subjects.count))) % subjects.count]
        fallbackSubject = subject
        backgroundConcept = theme?.backgroundConcept
        palette = project?.palette(name: name, variation: variation) ?? theme?.palette(index: Int(digest[1]), variation: variation) ?? palettes[(Int(digest[1]) + Int(variation % UInt64(palettes.count))) % palettes.count]
        composition = compositions[(Int(digest[2]) + Int(variation % UInt64(compositions.count))) % compositions.count]
    }

    static func nextVariation(after previous: UInt64) -> UInt64 {
        // Each table has an even number of entries. An odd offset changes all
        // three selections while providing a fresh seed for the language model.
        let offset = UInt64.random(in: 0...(UInt64.max / 2)) * 2 + 1
        let next = previous &+ offset
        return next == 0 ? 2 : next // Zero is reserved for the original artwork.
    }

    var concepts: [String] {
        [backgroundConcept].compactMap { $0 } + ["\(subject). \(palette).", "\(composition). Large recognizable silhouette."]
    }

    var fallbackConcepts: [String] {
        [backgroundConcept].compactMap { $0 } + ["\(fallbackSubject), \(palette)"]
    }
}
