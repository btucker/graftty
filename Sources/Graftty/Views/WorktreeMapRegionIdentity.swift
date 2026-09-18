import Foundation

/// Region assignments belong to worktree paths, not their current list positions.
enum WorktreeMapRegionIdentity {
    static let revision = 2

    static func assign(paths: [String], preserving existing: [String: Int]) -> [String: Int] {
        let paths = Set(paths).sorted()
        var result: [String: Int] = [:]
        var used = Set<Int>()
        for path in paths {
            if let id = existing[path], id >= 0, id < 1_000_000, used.insert(id).inserted { result[path] = id }
        }
        var next = 0
        for path in paths where result[path] == nil {
            while used.contains(next) { next += 1 }
            result[path] = next
            used.insert(next)
        }
        return result
    }

    static func design(_ id: Int) -> String {
        let colors = ["coral red", "turquoise", "sunflower gold", "lavender violet",
                      "spring green", "rose pink", "cobalt blue", "warm ivory",
                      "burnt orange", "icy cyan", "magenta", "chartreuse",
                      "deep plum", "seafoam mint", "saffron yellow", "powder blue"]
        let terrain = [
            "a dense orchard-like canopy of broad rounded crowns",
            "one large circular pool or hollow with an open smooth center",
            "broad open fields arranged in horizontal terraces",
            "a cluster of tall narrow spires forming a jagged skyline",
            "a fan of oversized leaves, sails or radial wedges",
            "one broad domed enclosure surrounded by sparse open space",
            "angular crystalline ridges with strong diagonal faces",
            "a soft cloud-like expanse with a few large floating islands",
            "stepped rectangular terraces with crisp right angles",
            "a deep crescent-shaped inlet framing an open center",
            "a field of large overlapping petals or umbrella shapes",
            "a bold branching delta with wide flat channels",
            "a monumental arch or ring framing a contrasting hollow",
            "a patchwork of large geometric plots with clear boundaries",
            "a sweeping dune-like ridge with smooth parallel bands",
            "one broad star-shaped formation surrounded by quiet space",
        ]
        let value = max(0, id)
        return "Dominant color field: \(colors[value % colors.count]). Terrain silhouette: \(terrain[(value % 16 + value / 16) % terrain.count]). Interpret this as a distinct place inside the project's world, in its chosen visual medium. The color belongs to the entire region, not small accents."
    }
}
