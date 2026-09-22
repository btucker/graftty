import AppKit
import CryptoKit

/// A single cartographic world. Model/user text never becomes SVG markup.
enum WorktreeSVGMap {
    /// Raster previews retain SVG linework instead of applying photographic detail suppression.
    final class Preview: NSImage {
        @MainActor fileprivate(set) var territoryColor: NSColor?
    }

    @MainActor static func preview(_ image: NSImage, district: District? = nil) -> NSImage {
        var accent: NSColor?
        if let district, palette.indices.contains(district.palette) {
            let value = UInt32(palette[district.palette].dropFirst(), radix: 16) ?? 0
            accent = NSColor(red: Double((value >> 16) & 255)/255,
                green: Double((value >> 8) & 255)/255, blue: Double(value & 255)/255, alpha: 1)
        }
        let result = Preview(size: image.size)
        result.territoryColor = accent
        for representation in image.representations { result.addRepresentation(representation) }
        return result
    }
    enum Motif: String, Codable, CaseIterable {
        case beacon, observatory, canal, gate, forge, archive, garden, harbor, bridge, windmill, plaza
    }
    struct District: Codable, Equatable {
        var motif: Motif
        var palette: Int
        var variation: UInt64
        // Missing in the first SVG cache format; upgrades preserve its color and seed.
        var variant: Int? = nil
    }
    private static let palette = ["#E8836F", "#66C5BC", "#DDB85E", "#AB93DB", "#93B86B",
                                  "#DA94B1", "#74A7D9", "#D9CAA1", "#D99B61", "#83BFCF", "#B190AE"]

    static func districts(in data: Data) -> [String: District]? {
        guard data.count < 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("<svg "), let start = text.range(of: "<metadata id=\"graftty-districts\">"),
              let end = text.range(of: "</metadata>", range: start.upperBound..<text.endIndex),
              let json = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound])),
              let result = try? JSONDecoder().decode([String: District].self, from: json),
              result.count <= 2000, result.values.allSatisfy({ (0..<palette.count).contains($0.palette) && ($0.variant.map { (0..<3).contains($0) } ?? true) }) else { return nil }
        return result
    }

    static func motif(name: String, context: String?, seed: UInt64) -> Motif {
        let groups: [(Motif, [String])] = [
            (.beacon, ["notif", "alert", "bell", "remind", "notify", "attention"]),
            (.observatory, ["search", "find", "discover", "query", "index", "research"]),
            (.canal, ["scroll", "history", "stream", "pagination", "paging"]),
            (.gate, ["auth", "permission", "security", "secure", "access", "login", "encrypt"]),
            (.archive, ["data", "store", "cache", "persist", "database", "backup", "archive"]),
            (.bridge, ["remote", "connect", "sync", "network", "ssh", "integrat", "protocol"]),
            (.windmill, ["performance", "speed", "latency", "optimiz", "fast", "cpu"]),
            (.harbor, ["deploy", "release", "ship", "publish", "launch", "bundle"]),
            (.garden, ["image", "icon", "design", "style", "theme", "color", "layout", "svg"]),
            (.forge, ["fix", "bug", "crash", "repair", "error", "test", "debug", "review", "inspect", "audit"]),
        ]
        func match(_ text: String) -> Motif? {
            let text = text.lowercased()
            let scores = groups.map { item in (item.0, item.1.filter { matches($0, in: text) }.count) }
            guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
            return best.0
        }
        return context.flatMap(match) ?? match(name) ?? Motif.allCases[Int(seed % UInt64(Motif.allCases.count))]
    }

    private static func matches(_ keyword: String, in text: String) -> Bool {
        // "Reviewing" is a review task; "preview" is not. Underscores and
        // hyphens both delimit task words in branch names.
        if keyword == "review" {
            return text.range(of: #"(?<![\p{L}\p{N}])review"#, options: .regularExpression) != nil
        }
        return text.contains(keyword)
    }

    @MainActor
    static func generate(_ input: WorktreeMapGeneration) throws -> Data {
        try Task.checkCancellation()
        let height = input.rows.reduce(0) { $0 + $1.height }
        guard height > 0, height <= 32000 else { throw ImageCreatorWorktreeIcon.Failure.invalidImage }
        var designs = input.previousSVG.flatMap(districts) ?? [:]
        if let paths = input.registeredPaths { designs = designs.filter { paths.contains($0.key) } }
        let ids = WorktreeMapRegionIdentity.assign(paths: input.rows.filter { !$0.isConnector }.map(\.path),
            preserving: Dictionary(input.rows.compactMap { row in row.regionID.map { (row.path, $0) } }, uniquingKeysWith: { first, _ in first }))
        // Allocate in path order so first composition does not depend on sidebar order.
        for row in input.rows.filter({ !$0.isConnector }).sorted(by: { $0.path < $1.path }) {
            let old = designs[row.path]
            if input.preservedPaths.contains(row.path), old?.variant != nil { continue }
            let seed = SHA256.hash(data: Data((input.project.path + "\n" + row.path).utf8)).prefix(8)
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let upgrading = old != nil && old?.variant == nil && !input.changingPaths.contains(row.path)
            let variation = upgrading ? old!.variation : old.map { $0.variation &+ 1 } ?? seed
            let family = upgrading ? old!.motif : row.path == input.project.path ? .plaza
                : motif(name: row.name, context: row.context, seed: seed)
            let neighbors = designs.filter { $0.key != row.path }.values
            let occupied = Set(neighbors.map(\.palette))
            let free = palette.indices.filter { !occupied.contains($0) && $0 != old?.palette }
            let preferred = (ids[row.path] ?? 0) % palette.count
            let chosen = upgrading ? old!.palette : old == nil && free.contains(preferred) ? preferred
                : free.isEmpty ? old?.palette ?? preferred : free[Int(variation % UInt64(free.count))]
            let used = neighbors.filter { $0.motif == family }.compactMap(\.variant)
            let unused = (0..<3).filter { !used.contains($0) }
            let oldVariant = old?.motif == family ? old?.variant : nil
            let available = unused.filter { $0 != oldVariant }
            let preferredVariant = preferredVariant(family, name: row.name, context: row.context, seed: seed)
            // Keep a unique silhouette at saturation; only reuse shapes when all
            // three already belong to neighbors. A new family can reuse its index.
            let candidates = !available.isEmpty ? available : !unused.isEmpty ? unused : Array(0..<3)
            let variant = candidates.contains(preferredVariant) ? preferredVariant
                : candidates.min { lhs, rhs in
                    let left = used.filter { $0 == lhs }.count
                    let right = used.filter { $0 == rhs }.count
                    return left == right ? lhs < rhs : left < right
                } ?? 0
            designs[row.path] = District(motif: family, palette: chosen, variation: variation, variant: variant)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode(designs).base64EncodedString()
        let base = input.theme?.svgBackground ?? "#30343A"
        let ink = input.theme?.svgForeground ?? "#ECE5CE"
        let medium = input.project.mapStyle ?? .contour
        let treatment = landmarkTreatment(medium, style: input.style)
        let landOpacity = input.style == .animation ? 0.28 : medium == .watercolor ? 0.18 : 0.20
        let accent = input.project.avatar.flatMap(avatarAccent) ?? "#C9B989"
        var terrain = ""
        var landmarks = ""
        var route = "M208 0"
        var top = 0.0
        for row in input.rows {
            let h = row.height
            defer { top += h }
            // Every segment meets at the same point with a vertical tangent.
            if row.isConnector {
                route += " L208 \(top + h)"
            } else {
                route += " C208 \(top + 14) 216 \(top + h * 0.3) 212 \(top + h * 0.5) S208 \(top + h - 14) 208 \(top + h)"
            }
            guard !row.isConnector, let district = designs[row.path] else {
                continue
            }
            let color = palette[district.palette]
            // A bounded shade change keeps explicit regeneration visible even
            // when every color and silhouette is already occupied.
            let districtOpacity = landOpacity + Double(district.variation % 3) * 0.035
            // Shared organic borders keep the territories contiguous. The color
            // field stays plain so titles and pane labels do not compete with texture.
            let edge = "M0 0 Q80 12 160 0 T320 0 L320 \(h) Q240 \(h-12) 160 \(h) T0 \(h) Z"
            terrain += "<path transform=\"translate(0 \(top))\" d=\"\(edge)\" fill=\"\(color)\" fill-opacity=\"\(districtOpacity)\"/>"
            // A fixed footprint below the title stays put as pane rows are added.
            landmarks += "<g transform=\"translate(174 \(top + 56)) scale(0.7)\" stroke=\"\(ink)\" \(treatment)>"
            landmarks += "<path d=\"M24 12 Q44 20 54 0\" fill=\"none\" stroke=\"\(accent)\" stroke-opacity=\"0.32\" stroke-width=\"1.3\"/>"
            let variant = district.variant ?? 0
            landmarks += "<g fill=\"\(color)\">\(landmark(district.motif, variant: variant))</g></g>"
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="\(height)" viewBox="0 0 320 \(height)">
        <metadata id="graftty-districts">\(metadata)</metadata>
        <rect width="320" height="\(height)" fill="\(base)"/>
        \(terrain)
        <g id="shared-route" fill="none" stroke-linecap="round"><path d="\(route)" stroke="\(accent)" stroke-opacity="0.32" stroke-width="1.2"/></g>
        \(landmarks)
        </svg>
        """
        return Data(svg.utf8)
    }

    /// Project media affect the landmark itself, never add background texture.
    private static func landmarkTreatment(_ medium: ProjectMapStyle, style: WorktreeArtworkStyle) -> String {
        let fill: Double
        let weight: Double
        let opacity: Double
        switch medium {
        case .woodcut: (fill, weight, opacity) = (0.95, 1.4, 0.55)
        case .screenprint: (fill, weight, opacity) = (1, 0.8, 0.35)
        case .ink: (fill, weight, opacity) = (0.25, 1.2, 0.8)
        case .watercolor: (fill, weight, opacity) = (0.65, 0.8, 0.3)
        case .risograph: (fill, weight, opacity) = (0.85, 1.0, 0.45)
        case .mosaic: (fill, weight, opacity) = (0.95, 2, 0.55)
        case .contour: (fill, weight, opacity) = (0.9, 1.1, 0.55)
        case .collage: (fill, weight, opacity) = (1, 0.5, 0.2)
        }
        return "fill-opacity=\"\(style == .sketch ? 0.16 : fill)\" stroke-opacity=\"\(style == .sketch ? 0.8 : opacity)\" stroke-width=\"\(weight)\" stroke-linejoin=\"\(medium == .mosaic ? "miter" : "round")\" stroke-linecap=\"round\""
    }

    static func landmark(_ motif: Motif, variant: Int) -> String {
        WorktreeTaskIllustration.svg(motif, variant: variant)
    }

    /// Match the task's purpose before using the path seed. Specific activities
    /// distinguish places within a family; raw task text is never stored in SVG.
    static func preferredVariant(_ motif: Motif, name: String, context: String?, seed: UInt64) -> Int {
        let hints: [(Int, [String])]
        switch motif {
        case .beacon: hints = [(2, ["push", "broadcast", "remote device", "deliver", "signal"]),
                              (1, ["bell", "claude", "attention", "approval", "human", "remind"]),
                              (0, ["monitor", "status", "watch", "health"])]
        case .forge: hints = [(2, ["test", "verify", "check", "assert", "validate"]),
                             (1, ["review", "inspect", "debug", "audit"]), (0, ["repair", "fix", "crash"])]
        case .garden: hints = [(2, ["browser", "gallery", "show", "preview", "display"]),
                              (1, ["generate", "icon", "print", "svg", "create"]),
                              (0, ["grow", "theme", "style", "color"])]
        case .archive: hints = [(2, ["encrypt", "secret", "private", "secure"]),
                               (1, ["partition", "bucket", "shard", "capacity"]),
                               (0, ["recover", "backup", "restore", "history"])]
        case .observatory: hints = [(2, ["listen", "incoming", "event", "subscribe"]),
                                   (1, ["index", "catalog", "measure", "survey"]),
                                   (0, ["research", "explore", "search", "discover"])]
        case .canal: hints = [(2, ["fork", "branch", "split", "route"]), (1, ["page", "step", "scroll", "pagination"]),
                             (0, ["buffer", "stream", "flow"])]
        case .gate: hints = [(2, ["remote", "temporary", "invite"]), (1, ["permission", "role", "policy"]),
                            (0, ["login", "auth", "account"])]
        case .bridge: hints = [(2, ["sync", "live", "realtime"]), (1, ["batch", "migrate", "transfer"]),
                              (0, ["connect", "ssh", "protocol"])]
        case .windmill: hints = [(2, ["parallel", "concurrent", "async"]), (1, ["cache", "reuse", "recycl"]),
                                (0, ["speed", "latency", "performance"])]
        case .harbor: hints = [(2, ["launch", "startup", "boot"]), (1, ["build", "bundle", "package"]),
                              (0, ["release", "publish", "deploy"])]
        case .plaza: return 0
        }
        for text in [context, name].compactMap({ $0?.lowercased() }) {
            if let match = hints.first(where: { hint in hint.1.contains { matches($0, in: text) } }) { return match.0 }
        }
        return Int(seed % 3)
    }

    @MainActor private static func avatarAccent(_ data: Data) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let color = NSColor(WorktreeArtworkPalette.colors(image)[0]).usingColorSpace(.deviceRGB)
        guard let color else { return nil }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
