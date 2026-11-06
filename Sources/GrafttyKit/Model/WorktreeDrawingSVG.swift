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

    public init(svg: String, hue: Double) {
        self.svg = svg
        self.revision = SHA256.hash(data: Data(svg.utf8)).map { String(format: "%02x", $0) }.joined() + ":\(Int(hue.rounded()))"
    }
}

/// @spec AGENT-3.33
/// An agent's worktree drawing is untrusted input. Only a small, inert SVG
/// subset passes: shapes, groups, gradients and text, painted with palette
/// tokens that the host fills from the worktree's assigned color.
public enum WorktreeDrawingSVG {
    public static let maxBytes = AttentionRecap.maxIconBytes
    public static let tokens: Set<String> = ["primary", "primary-light", "primary-dark", "accent", "accent-light", "ink", "white", "none"]

    public enum Rejection: Error, Equatable, CustomStringConvertible {
        case tooLarge, malformed
        case element(String), attribute(String), paint(String), reference(String)

        public var description: String {
            switch self {
            case .tooLarge: "the drawing exceeds \(WorktreeDrawingSVG.maxBytes) bytes"
            case .malformed: "the drawing must be one well-formed <svg viewBox=\"0 0 64 64\"> element without comments, CDATA, DOCTYPE or processing instructions"
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
                guard name == "svg", attributes["viewBox"]?.split(separator: " ").map(String.init) == ["0", "0", "64", "64"] else {
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

        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            fail(.malformed, parser)
        }

        private func fail(_ reason: Rejection, _ parser: XMLParser) {
            if rejection == nil { rejection = reason }
            parser.abortParsing()
        }
    }
}
