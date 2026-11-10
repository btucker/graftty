import Foundation
import GrafttyProtocol
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A validated agent drawing. The revision changes with the drawing or its
/// hue, so clients refetch exactly when the rendered image changes.
public struct WorktreeDrawing: Codable, Sendable, Equatable {
    public var svg: String
    public var revision: String
    /// The agent's few words naming the drawing (AGENT-3.45); nil for older drawings.
    public var description: String?
    /// When the drawing was adopted; nil for older drawings.
    public var adoptedAt: Date?

    public init(svg: String, hue: Double, description: String? = nil, adoptedAt: Date? = nil) {
        self.svg = svg
        self.description = description
        self.adoptedAt = adoptedAt
        self.revision = SHA256.hash(data: Data(svg.utf8)).map { String(format: "%02x", $0) }.joined() + ":\(Int(hue.rounded()))"
    }

    /// Older drawings are square; current ones are drawn wide.
    public var canvas: WorktreeDrawingSVG.Canvas { WorktreeDrawingSVG.canvas(of: svg) ?? .square }

    /// @spec AGENT-3.46
    /// While a linked worktree still needs a wide drawing, the descriptions of
    /// the most recently adopted other drawings in its repository, newest first,
    /// so its agent can draw something different.
    public static func descriptionsInUse(besidesWorktreePath path: String, in repos: [RepoEntry], limit: Int = 8) -> [String] {
        guard let repo = repos.first(where: { $0.path != path && $0.worktrees.contains { $0.path == path } }),
              repo.worktrees.first(where: { $0.path == path })?.drawing?.canvas != .wide else { return [] }
        return repo.worktrees.filter { $0.path != path }.compactMap(\.drawing)
            .filter { $0.description != nil }
            .sorted { ($0.adoptedAt ?? .distantPast) > ($1.adoptedAt ?? .distantPast) }
            .prefix(limit).compactMap(\.description)
    }
}

/// @spec AGENT-3.33
/// An agent's worktree drawing is untrusted input. Only a small, inert SVG
/// subset passes: shapes, groups, gradients and text, painted with palette
/// tokens that the host fills from the worktree's assigned color.
public enum WorktreeDrawingSVG {
    public static let maxBytes = AttentionRecap.maxIconBytes

    /// @spec AGENT-3.42
    /// A drawing is wide (96 by 64) so it fills a row's identity slot and a
    /// pinned tile; square drawings from before stay valid.
    public enum Canvas: Sendable, Equatable {
        case square, wide

        public var viewBox: [String] { self == .wide ? ["0", "0", "96", "64"] : ["0", "0", "64", "64"] }
        /// Width over height, for rendering and layout.
        public var aspect: Double { self == .wide ? 1.5 : 1 }

        init?(viewBox: String?) {
            let parts = viewBox?.split(separator: " ").map(String.init)
            guard let canvas = [Canvas.wide, .square].first(where: { $0.viewBox == parts }) else { return nil }
            self = canvas
        }
    }

    /// The canvas a validated drawing uses, read from its root element.
    public static func canvas(of svg: String) -> Canvas? {
        guard let open = svg.range(of: "<svg"), let close = svg[open.upperBound...].firstIndex(of: ">") else { return nil }
        let tag = svg[open.upperBound..<close]
        guard let attribute = tag.range(of: "viewBox=") , let quote = tag[attribute.upperBound...].first,
              quote == "'" || quote == "\"" else { return nil }
        let valueStart = tag.index(after: attribute.upperBound)
        guard let valueEnd = tag[valueStart...].firstIndex(of: quote) else { return nil }
        return Canvas(viewBox: String(tag[valueStart..<valueEnd]))
    }
    public static let tokens: Set<String> = ["primary", "primary-light", "primary-dark", "accent", "accent-light", "ink", "white", "none"]

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case tooLarge, malformed
        case element(String), attribute(String), paint(String), reference(String)

        public var description: String {
            switch self {
            case .tooLarge: "the drawing exceeds \(WorktreeDrawingSVG.maxBytes) bytes"
            case .malformed: "the drawing must be one well-formed <svg viewBox=\"0 0 96 64\"> element without comments, CDATA, DOCTYPE or processing instructions"
            case .element(let name): "<\(name)> is not allowed in a drawing; use path, rect, circle, ellipse, line, polyline, polygon, g, text and gradients"
            case .attribute(let name): "the \(name) attribute is not allowed in a drawing"
            case .paint(let value): "paint \(value) is not a palette token; use \(WorktreeDrawingSVG.tokens.sorted().joined(separator: ", ")) or url(#gradient)"
            case .reference(let id): "url(#\(id)) does not name a gradient defined in the drawing"
            }
        }
    }

    static let elements: Set<String> = ["svg", "g", "defs", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
                                        "text", "tspan", "linearGradient", "radialGradient", "stop", "title"]
    static let paintAttributes: Set<String> = ["fill", "stroke", "stop-color"]
    static let attributes: Set<String> = paintAttributes.union([
        "xmlns", "viewBox", "width", "height", "id", "d", "x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy",
        "points", "transform", "opacity", "fill-opacity", "fill-rule", "stroke-width", "stroke-linecap", "stroke-linejoin",
        "stroke-dasharray", "stroke-dashoffset", "stroke-opacity", "stroke-miterlimit", "offset", "stop-opacity",
        "gradientUnits", "gradientTransform", "spreadMethod", "font-family", "font-size", "font-weight", "font-style",
        "text-anchor", "dominant-baseline", "letter-spacing", "dx", "dy",
    ])

    /// Returns the trimmed drawing, or throws the first reason it is unsafe.
    public static func validate(_ svg: String) throws -> String {
        let trimmed = svg.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maxBytes else { throw Rejection.tooLarge }
        // Entity declarations can expand far past the size limit.
        guard !trimmed.contains("<!") else { throw Rejection.malformed }
        let checker = Checker()
        let parser = XMLParser(data: Data(trimmed.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = checker
        let parsed = parser.parse()
        if let rejection = checker.rejection { throw rejection }
        guard parsed, checker.sawRoot else { throw Rejection.malformed }
        if let missing = checker.references.first(where: { !checker.ids.contains($0) }) { throw Rejection.reference(missing) }
        return trimmed
    }

    private final class Checker: NSObject, XMLParserDelegate {
        var rejection: Rejection?
        var sawRoot = false
        var ids = Set<String>()
        var references = [String]()
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            defer { depth += 1 }
            guard rejection == nil else { return }
            if depth == 0 {
                guard name == "svg", Canvas(viewBox: attributes["viewBox"]) != nil else {
                    return fail(.malformed, parser)
                }
                sawRoot = true
            }
            guard WorktreeDrawingSVG.elements.contains(name) else { return fail(.element(name), parser) }
            for (key, value) in attributes.sorted(by: { $0.key < $1.key }) {
                guard WorktreeDrawingSVG.attributes.contains(key) else { return fail(.attribute(key), parser) }
                if key == "id" { ids.insert(value) }
                guard WorktreeDrawingSVG.paintAttributes.contains(key) else { continue }
                if WorktreeDrawingSVG.tokens.contains(value) { continue }
                if value.hasPrefix("url(#"), value.hasSuffix(")") {
                    let id = String(value.dropFirst(5).dropLast())
                    if !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                        references.append(id)
                        continue
                    }
                }
                return fail(.paint(value), parser)
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { depth -= 1 }

        /// Linux's parser recovers from errors and still returns true from
        /// parse(), so a reported error must reject the drawing by itself.
        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            fail(.malformed, parser)
        }

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            fail(.malformed, parser)
        }

        private func fail(_ reason: Rejection, _ parser: XMLParser) {
            if rejection == nil { rejection = reason }
            parser.abortParsing()
        }
    }
}
