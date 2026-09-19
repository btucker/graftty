import AppKit
import CryptoKit

/// A single cartographic world. Model/user text never becomes SVG markup.
enum WorktreeSVGMap {
    /// Raster previews retain SVG linework instead of applying photographic detail suppression.
    final class Preview: NSImage {}

    @MainActor static func preview(_ image: NSImage) -> NSImage {
        let result = Preview(size: image.size)
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
            (.forge, ["fix", "bug", "crash", "repair", "error", "test", "debug"]),
        ]
        func match(_ text: String) -> Motif? {
            let text = text.lowercased()
            let scores = groups.map { item in (item.0, item.1.filter { text.contains($0) }.count) }
            guard let best = scores.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
            return best.0
        }
        return context.flatMap(match) ?? match(name) ?? Motif.allCases[Int(seed % UInt64(Motif.allCases.count))]
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
        let landOpacity = input.style == .animation ? 0.48 : medium == .watercolor ? 0.30 : 0.38
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
        if variant == 1 { return terraceLandmark(motif) }
        if variant == 2 { return islandLandmark(motif) }
        switch motif {
        case .beacon:
            return "<path d=\"M-11 19 L-7 -13 L7 -13 L11 19 Z M-9 -13 V-23 H9 V-13 Z M-12 -23 L0 -30 L12 -23 Z\"/><path d=\"M-5 -19 H5 M-6 2 H6 M-8 12 H8 M-18 -19 L-28 -23 M18 -19 L28 -23\" fill=\"none\"/>"
        case .observatory:
            return "<path d=\"M-20 17 V-3 A20 20 0 0 1 20 -3 V17 Z M-20 -3 H20 M-2 -22 V-3\"/><path d=\"M2 -7 L18 -24 L24 -18 L8 -1 Z\"/><path d=\"M-12 17 V6 H-5 V17 M6 6 H13 V12 H6 Z\"/>"
        case .canal:
            return "<path d=\"M-24 -16 L-14 -20 L-10 23 H-21 Z M14 -20 L24 -16 L21 23 H10 Z M-14 -5 H14 V3 H-14 Z\"/><path d=\"M-6 -22 Q4 -12 -5 -3 T-3 23 M3 -22 Q13 -12 4 -3 T6 23\" fill=\"none\"/>"
        case .gate:
            return "<path d=\"M-24 20 V-20 H-17 V-14 H-10 V-20 H-3 V-9 H3 V-20 H10 V-14 H17 V-20 H24 V20 H9 V3 A9 9 0 0 0 -9 3 V20 Z\"/><path d=\"M-19 -6 H-13 M13 -6 H19 M-19 5 H-13 M13 5 H19\"/>"
        case .archive:
            return "<path d=\"M-23 20 V-15 L0 -27 L23 -15 V20 Z M-23 -15 H23 M-16 -10 V16 M-6 -10 V16 M6 -10 V16 M16 -10 V16 M-27 20 H27 M-25 24 H25\"/>"
        case .forge:
            return "<path d=\"M-24 20 V-8 L-8 -19 L5 -8 V20 Z M5 20 V-3 L24 -12 V20 Z M14 -7 V-28 H21 V-10 M-17 20 V6 H-7 V20\"/><path d=\"M-17 -4 H-8 V1 H-17 Z M10 6 H19 V12 H10 Z\"/>"
        case .garden:
            return "<path d=\"M-24 19 L-18 -12 L0 -24 L18 -12 L24 19 Z M-18 -12 H18 M0 -24 V19 M-18 -12 L-8 19 M18 -12 L8 19 M-22 5 H22\"/><path d=\"M-6 14 Q-18 -1 -7 -2 Q2 1 0 14 Q1 -6 12 -5 Q23 7 2 15\"/>"
        case .harbor:
            return "<path d=\"M-27 13 H27 L16 24 H-17 Z M0 13 V-28 L22 7 H3 M-3 -22 L-21 7 H-3 Z\"/><path d=\"M-27 29 Q-17 24 -7 29 T13 29 T29 29\" fill=\"none\"/>"
        case .bridge:
            return "<path d=\"M-28 4 Q0 -23 28 4 V18 H21 Q0 -12 -21 18 H-28 Z M-27 0 V-12 H-20 V-5 M20 -5 V-12 H27 V0\"/><path d=\"M-17 -1 V8 M-8 -7 V2 M1 -9 V0 M10 -6 V3 M19 0 V9\"/>"
        case .windmill:
            return "<path d=\"M-13 24 L-7 -13 H7 L13 24 Z\"/><path d=\"M0 -8 L-21 -28 L-26 -20 Z M0 -8 L21 -28 L26 -20 Z M0 -8 L21 12 L26 4 Z M0 -8 L-21 12 L-26 4 Z\"/><circle cx=\"0\" cy=\"-8\" r=\"4\"/>"
        case .plaza:
            return "<ellipse cx=\"0\" cy=\"15\" rx=\"25\" ry=\"11\"/><ellipse cx=\"0\" cy=\"11\" rx=\"19\" ry=\"7\"/><path d=\"M-5 10 V-12 H5 V10 Z M0 -12 Q-23 -12 -19 -29 Q-3 -30 0 -12 Q2 -32 20 -28 Q20 -11 0 -12\"/>"
        }
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
            if let match = hints.first(where: { hint in hint.1.contains(where: text.contains) }) { return match.0 }
        }
        return Int(seed % 3)
    }

    /// A second set of silhouettes: civic buildings and terraced infrastructure.
    private static func terraceLandmark(_ motif: Motif) -> String {
        switch motif {
        case .beacon: // Open bell campanile, distinct from the closed lighthouse.
            return "<path d=\"M-17 22 V-18 L0 -30 L17 -18 V22 H9 V-13 H-9 V22 Z M-20 -18 H20\"/><path d=\"M-8 1 Q-5 -1 -5 -8 A5 5 0 0 1 5 -8 Q5 -1 8 1 Z\"/><circle cx=\"0\" cy=\"5\" r=\"2\"/><path d=\"M-9 15 H9 M-9 20 H9 M-26 -5 Q-32 0 -26 5 M26 -5 Q32 0 26 5\" fill=\"none\"/>"
        case .observatory: // Armillary sphere and survey pedestal.
            return "<path d=\"M-13 22 L-8 10 H8 L13 22 Z M0 10 V-28\"/><circle cx=\"0\" cy=\"-9\" r=\"18\"/><ellipse cx=\"0\" cy=\"-9\" rx=\"8\" ry=\"18\" fill=\"none\"/><ellipse cx=\"0\" cy=\"-9\" rx=\"22\" ry=\"6\" transform=\"rotate(-25 0 -9)\" fill=\"none\"/>"
        case .canal: // A stepped cascade instead of a lock.
            return "<path d=\"M-23 -24 H-5 V-9 H9 V6 H24 V22 H-23 Z\"/><path d=\"M-17 -19 H-10 V-4 H3 V11 H18 V22 M-23 -9 H-5 M-23 6 H9 M-23 22 H24\" fill=\"none\"/>"
        case .gate: // A raised portcullis and its counterweights.
            return "<path d=\"M-25 23 V-23 H-16 V23 Z M16 23 V-23 H25 V23 Z M-16 -20 H16 V-12 H-16 Z\"/><path d=\"M-11 -12 V9 M-4 -12 V9 M4 -12 V9 M11 -12 V9 M-16 -5 H16 M-16 3 H16 M-28 23 H28\" fill=\"none\"/>"
        case .archive: // Stacked granary silos.
            return "<path d=\"M-27 22 V-8 L-17 -20 L-7 -8 V22 Z M-7 22 V-17 L4 -30 L15 -17 V22 Z M15 22 V-3 L26 -15 L32 -3 V22 Z\"/><path d=\"M-27 -8 H-7 M-7 -17 H15 M15 -3 H32 M-23 7 H-11 M-2 2 H10 M20 10 H28\" fill=\"none\"/>"
        case .forge: // Inspection hall with a large magnifying lens.
            return "<path d=\"M-27 22 V1 L-16 -10 L-5 1 V22 Z M-27 1 H-5 M-20 22 V10 H-12 V22\"/><circle cx=\"9\" cy=\"-11\" r=\"16\"/><circle cx=\"9\" cy=\"-11\" r=\"10\"/><path d=\"M18 2 L29 19 L23 23 L12 6 Z M4 -11 L8 -7 L15 -16\"/>"
        case .garden: // Color-making atelier with a printing roller.
            return "<path d=\"M-26 22 V-17 H-19 V22 Z M19 22 V-17 H26 V22 Z M-26 -17 H26 V-10 H-26 Z M-19 12 H19 V18 H-19 Z\"/><rect x=\"-14\" y=\"-6\" width=\"28\" height=\"12\" rx=\"6\"/><path d=\"M0 -10 V-26 M-9 -26 H9 M-9 6 V12 M9 6 V12 M-12 18 L-17 25 H17 L12 18\"/>"
        case .harbor: // Dockside crane.
            return "<path d=\"M-21 23 V-24 H-13 V23 Z M-24 -24 H25 V-17 H-24 Z M-13 13 L13 -17 M-27 23 H-7\"/><path d=\"M20 -17 V2 Q20 10 13 7 M4 23 V12 H24 V23 Z\"/>"
        case .bridge: // High aqueduct.
            return "<path d=\"M-30 -10 H30 V23 H23 V7 A7 7 0 0 0 9 7 V23 H3 V7 A7 7 0 0 0 -11 7 V23 H-17 V7 A7 7 0 0 0 -30 7 Z M-30 -17 H30 V-10 H-30 Z\"/><path d=\"M-24 -17 V-23 M-8 -17 V-23 M8 -17 V-23 M24 -17 V-23\"/>"
        case .windmill: // Broad waterwheel.
            return "<path d=\"M-29 22 V-6 L-17 -16 L-5 -6 V22 Z\"/><circle cx=\"10\" cy=\"1\" r=\"23\"/><circle cx=\"10\" cy=\"1\" r=\"16\"/><path d=\"M10 -22 V24 M-13 1 H33 M-6 -15 L26 17 M-6 17 L26 -15\" fill=\"none\"/><circle cx=\"10\" cy=\"1\" r=\"4\"/>"
        case .plaza: // Civic clock tower.
            return "<path d=\"M-12 23 V-23 L0 -31 L12 -23 V23 Z M-19 23 H19 M-9 16 H9\"/><circle cx=\"0\" cy=\"-11\" r=\"8\"/><path d=\"M0 -17 V-11 L5 -8 M-4 23 V7 H4 V23\"/>"
        }
    }

    /// A third set: open structures around islands, docks, and scattered ground.
    private static func islandLandmark(_ motif: Motif) -> String {
        switch motif {
        case .beacon: // Signal mast and broad broadcast arcs.
            return "<path d=\"M-13 23 L0 -22 L13 23 Z M-10 14 H10 M-7 3 H7 M-4 -8 H4\"/><circle cx=\"0\" cy=\"-24\" r=\"4\"/><path d=\"M-12 -29 Q-23 -20 -12 -11 M12 -29 Q23 -20 12 -11 M-22 -32 Q-38 -20 -22 -7 M22 -32 Q38 -20 22 -7\" fill=\"none\"/>"
        case .observatory: // Dish antenna, open asymmetric silhouette.
            return "<path d=\"M-10 24 L-1 6 H7 L15 24 Z M-25 -24 Q-27 12 18 4 Z\"/><path d=\"M-25 -24 L-5 -7 L18 4 M-5 -7 L12 -25\" fill=\"none\"/><circle cx=\"12\" cy=\"-25\" r=\"3\"/>"
        case .canal: // Forking sluices and three watercourses.
            return "<path d=\"M-6 -28 H6 V-8 L28 9 L22 17 L0 1 L-22 17 L-28 9 L-6 -8 Z\"/><path d=\"M0 -23 V-4 M-23 22 Q-17 17 -12 23 M-5 20 Q0 15 5 21 M14 24 Q21 18 27 23\" fill=\"none\"/>"
        case .gate: // Watch island with a drawbridge.
            return "<path d=\"M-24 19 V-19 H-18 V-25 H-10 V-19 H-4 V19 Z M-17 -10 H-11 V-3 H-17 Z M-4 9 L23 -6 L28 2 L-4 22 Z\"/><path d=\"M-4 -15 L23 -6 M-4 -10 L28 2 M4 5 L9 16 M14 0 L19 10\" fill=\"none\"/>"
        case .archive: // Secure domed vault.
            return "<path d=\"M-26 22 V-1 A26 26 0 0 1 26 -1 V22 Z M-26 -1 H26\"/><circle cx=\"0\" cy=\"7\" r=\"13\"/><circle cx=\"0\" cy=\"7\" r=\"4\"/><path d=\"M0 -6 V3 M0 11 V20 M-13 7 H-4 M4 7 H13 M-20 -10 H-8 M8 -10 H20\"/>"
        case .forge: // Test gantry with suspended load and calibration ticks.
            return "<path d=\"M-27 24 V-27 H-20 V24 Z M20 24 V-27 H27 V24 Z M-20 -25 H20 V-18 H-20 Z\"/><path d=\"M0 -18 V-4 M-9 -4 H9 L15 12 H-15 Z M-15 20 H15 M-16 24 H16 M-20 -9 H-14 M-20 0 H-14 M-20 9 H-14\"/>"
        case .garden: // Gallery pavilion with wide fan roof and picture frames.
            return "<path d=\"M-27 -8 L-17 -23 H17 L27 -8 Z M-22 -8 V23 H22 V-8 M-17 -23 L-8 -8 M0 -23 V-8 M17 -23 L8 -8\"/><path d=\"M-16 -1 H-3 V14 H-16 Z M3 -1 H16 V14 H3 Z M-16 10 L-11 4 L-3 12 M3 10 L8 3 L16 11 M-27 23 H27\"/>"
        case .harbor: // Launch slip and ship's prow.
            return "<path d=\"M-23 -6 L0 -27 L23 -6 L15 15 H-15 Z M0 -27 V15 M-16 -2 H16 M-9 -15 H9\"/><path d=\"M-29 22 L-18 15 M29 22 L18 15 M-23 28 Q-12 21 0 28 T25 28\" fill=\"none\"/>"
        case .bridge: // Suspension bridge with two tall cable pylons.
            return "<path d=\"M-19 24 V-26 H-14 V24 Z M14 24 V-26 H19 V24 Z M-31 8 H31 V13 H-31 Z\"/><path d=\"M-31 5 L-17 -22 Q0 14 17 -22 L31 5 M-8 -8 V8 M0 -4 V8 M8 -8 V8\" fill=\"none\"/>"
        case .windmill: // Sail-powered turbine, asymmetric blades.
            return "<path d=\"M-5 24 L-2 -8 H3 L7 24 Z M0 -8 L-10 -31 L1 -29 Z M0 -8 L27 -8 L21 1 Z M0 -8 L-14 16 L-20 7 Z\"/><circle cx=\"0\" cy=\"-8\" r=\"4\"/>"
        case .plaza: // Town well and canopy.
            return "<path d=\"M-22 23 V8 H22 V23 Z M-17 8 V-15 M17 8 V-15 M-27 -15 L0 -29 L27 -15 Z\"/><path d=\"M-17 -6 H17 M0 -6 V10 M-5 10 H5 L4 18 H-4 Z M-22 16 H22 M-10 16 V23 M10 8 V16\"/>"
        }
    }

    @MainActor private static func avatarAccent(_ data: Data) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let color = NSColor(WorktreeArtworkPalette.colors(image)[0]).usingColorSpace(.deviceRGB)
        guard let color else { return nil }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
