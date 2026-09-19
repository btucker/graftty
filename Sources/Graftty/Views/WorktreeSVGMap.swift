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
    }
    private static let palette = ["#E8836F", "#66C5BC", "#DDB85E", "#AB93DB", "#93B86B",
                                  "#DA94B1", "#74A7D9", "#D9CAA1", "#D99B61", "#83BFCF", "#B190AE"]

    static func districts(in data: Data) -> [String: District]? {
        guard data.count < 8 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("<svg "), let start = text.range(of: "<metadata id=\"graftty-districts\">"),
              let end = text.range(of: "</metadata>", range: start.upperBound..<text.endIndex),
              let json = Data(base64Encoded: String(text[start.upperBound..<end.lowerBound])),
              let result = try? JSONDecoder().decode([String: District].self, from: json),
              result.count <= 2000, result.values.allSatisfy({ (0..<palette.count).contains($0.palette) }) else { return nil }
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
        for row in input.rows where !row.isConnector {
            if input.preservedPaths.contains(row.path), designs[row.path] != nil { continue }
            let seed = SHA256.hash(data: Data((input.project.path + "\n" + row.path).utf8)).prefix(8)
                .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            let variation = designs[row.path].map { $0.variation &+ 1 } ?? seed
            let occupied = Set(designs.filter { $0.key != row.path }.values.map(\.palette))
            let free = palette.indices.filter { !occupied.contains($0) && $0 != designs[row.path]?.palette }
            let preferred = (ids[row.path] ?? 0) % palette.count
            let chosen = designs[row.path] == nil && free.contains(preferred) ? preferred
                : free.isEmpty ? designs[row.path]?.palette ?? preferred : free[Int(variation % UInt64(free.count))]
            designs[row.path] = District(motif: row.path == input.project.path ? .plaza
                : motif(name: row.name, context: row.context, seed: seed),
                palette: chosen, variation: variation)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let metadata = try encoder.encode(designs).base64EncodedString()
        let base = input.theme?.svgBackground ?? "#30343A"
        let ink = input.theme?.svgForeground ?? "#ECE5CE"
        let medium = input.project.mapStyle ?? .contour
        let weight = input.style == .sketch || medium == .ink ? 0.9 : medium == .screenprint ? 2.0 : 1.4
        let landOpacity = input.style == .animation ? 0.36 : medium == .watercolor ? 0.16 : medium == .screenprint ? 0.3 : 0.23
        let accent = input.project.avatar.flatMap(avatarAccent) ?? "#C9B989"
        var definitions = ""
        var terrain = ""
        var landmarks = ""
        var route = "M208 0"
        var top = 0.0
        for (index, row) in input.rows.enumerated() {
            let h = row.height
            defer { top += h }
            // Every segment meets at the same point with a vertical tangent.
            route += " C208 \(top + 14) 216 \(top + h * 0.3) 212 \(top + h * 0.5) S208 \(top + h - 14) 208 \(top + h)"
            guard !row.isConnector, let district = designs[row.path] else {
                terrain += "<path d=\"M248 \(top) C272 \(top+h*0.3) 258 \(top+h*0.7) 248 \(top+h)\" fill=\"none\" stroke=\"\(accent)\" opacity=\"0.1\"/>"
                continue
            }
            let color = palette[district.palette]
            let offset = Double(district.variation % 11)
            // The lower boundary is exactly the next district's upper boundary.
            let edge = "M0 0 Q80 12 160 0 T320 0 L320 \(h) Q240 \(h-12) 160 \(h) T0 \(h) Z"
            definitions += "<clipPath id=\"district-\(index)\"><path d=\"\(edge)\"/></clipPath>"
            terrain += "<g transform=\"translate(0 \(top))\"><path d=\"\(edge)\" fill=\"\(color)\" fill-opacity=\"\(landOpacity)\"/>"
            let dash = medium == .risograph ? " stroke-dasharray=\"1 4\" stroke-linecap=\"round\"" : ""
            terrain += "<g clip-path=\"url(#district-\(index))\" fill=\"none\" stroke=\"\(color)\" stroke-width=\"\(weight)\" opacity=\"0.42\"\(dash)>"
            terrain += pattern(district.motif, height: h, offset: offset, medium: medium)
            terrain += "</g></g>"
            // Buildings and routes use the same materials throughout the project.
            landmarks += "<g transform=\"translate(174 \(top + 40))\" stroke=\"\(ink)\" stroke-width=\"\(weight)\" stroke-linejoin=\"round\" stroke-linecap=\"round\">"
            landmarks += "<path d=\"M20 6 Q30 12 38 6\" fill=\"none\" stroke=\"\(accent)\" stroke-width=\"3\"/>"
            landmarks += "<ellipse cx=\"0\" cy=\"18\" rx=\"29\" ry=\"11\" fill=\"\(color)\" fill-opacity=\"0.38\" stroke-opacity=\"0.3\"/>"
            landmarks += "<g fill=\"\(base)\">\(landmark(district.motif))</g>"
            landmarks += "<g fill=\"\(color)\" stroke=\"\(accent)\" stroke-width=\"0.7\">"
            for n in 0..<3 {
                let x = -28 - n * 7
                let y = 8 + Int(district.variation % 5) + n * 3
                landmarks += "<path d=\"M\(x) \(y) l4 -5 5 3 -1 6 -6 0 Z\"/>"
            }
            landmarks += "</g></g>"
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="\(height)" viewBox="0 0 320 \(height)">
        <metadata id="graftty-districts">\(metadata)</metadata>
        <defs>\(definitions)</defs>
        <rect width="320" height="\(height)" fill="\(base)"/>
        \(terrain)
        <g id="shared-route" fill="none" stroke-linecap="round"><path d="\(route)" stroke="\(accent)" stroke-opacity="0.12" stroke-width="13"/><path d="\(route)" stroke="\(accent)" stroke-opacity="0.65" stroke-width="2"/><path d="\(route)" stroke="\(ink)" stroke-opacity="0.22" stroke-width="0.6"/></g>
        \(landmarks)
        </svg>
        """
        return Data(svg.utf8)
    }

    private static func pattern(_ motif: Motif, height: Double, offset: Double, medium: ProjectMapStyle) -> String {
        var result = ""
        for n in 0..<min(30, Int(height / 14) + 1) {
            let y = Double(n * 17) + offset
            switch motif {
            case .beacon, .observatory, .plaza:
                let r = 24 + n * 14
                result += "<ellipse cx=\"174\" cy=\"40\" rx=\"\(r)\" ry=\"\(Double(r)*0.6)\"/>"
            case .canal, .harbor:
                result += "<path d=\"M116 \(y) C148 \(y-12) 170 \(y+14) 205 \(y) S268 \(y-10) 320 \(y+2)\"/>"
            case .gate, .archive:
                result += "<path d=\"M124 \(y) h188 m-164 0 v12 m32 -12 v12 m32 -12 v12 m32 -12 v12 m32 -12 v12\"/>"
            case .garden:
                result += "<path d=\"M126 \(y+12) Q152 \(y-5) 170 \(y+8) T218 \(y+7) T272 \(y+8) T320 \(y+4)\"/>"
            case .forge:
                result += "<path d=\"M125 \(y) l25 10 25 -10 25 10 25 -10 25 10 25 -10 25 10\"/>"
            case .bridge:
                result += "<path d=\"M132 \(y+14) Q146 \(y-8) 160 \(y+14) Q174 \(y-8) 188 \(y+14) Q202 \(y-8) 216 \(y+14) Q230 \(y-8) 244 \(y+14)\"/>"
            case .windmill:
                result += "<path d=\"M120 \(y+10) Q216 \(y-14) 314 \(y)\"/>"
            }
        }
        if medium == .woodcut || medium == .ink {
            result += "<path d=\"M250 14 l30 10 m-26 -2 l30 10 m-26 -2 l30 10\"/>"
        }
        if medium == .mosaic {
            for y in stride(from: 8, to: Int(height), by: 24) {
                result += "<path d=\"M136 \(y) l12 -8 12 8 -12 8 Z M184 \(y) l12 -8 12 8 -12 8 Z M232 \(y) l12 -8 12 8 -12 8 Z M280 \(y) l12 -8 12 8 -12 8 Z\"/>"
            }
        } else if medium == .collage {
            result += "<path d=\"M125 0 L153 17 L138 44 L158 71 L142 \(height) M278 0 L254 31 L275 61 L260 \(height)\" stroke-width=\"5\" opacity=\"0.4\"/>"
        } else if medium == .watercolor {
            result += "<ellipse cx=\"220\" cy=\"\(height/2)\" rx=\"92\" ry=\"\(height*0.45)\" stroke-width=\"12\" opacity=\"0.15\"/>"
        }
        return result
    }

    private static func landmark(_ motif: Motif) -> String {
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

    @MainActor private static func avatarAccent(_ data: Data) -> String? {
        guard let image = NSImage(data: data) else { return nil }
        let color = NSColor(WorktreeArtworkPalette.colors(image)[0]).usingColorSpace(.deviceRGB)
        guard let color else { return nil }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}
