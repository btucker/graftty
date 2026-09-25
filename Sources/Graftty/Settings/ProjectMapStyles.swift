import Combine
import CryptoKit
import Foundation

enum ProjectMapStyle: String, CaseIterable, Codable, Sendable {
    case woodcut, screenprint, ink, watercolor, risograph, mosaic, contour, collage

    var label: String {
        switch self {
        case .woodcut: "Woodcut"
        case .screenprint: "Screen print"
        case .ink: "Pen and ink"
        case .watercolor: "Watercolor"
        case .risograph: "Risograph"
        case .mosaic: "Mosaic"
        case .contour: "Contour drawing"
        case .collage: "Paper collage"
        }
    }

    var character: String {
        switch self {
        case .woodcut: "Flat woodcut print, bold carved silhouettes, sparse hatching, visible uneven ink edges."
        case .screenprint: "Flat editorial screen print, broad opaque spot-color shapes, crisp silhouettes and restrained registration offsets."
        case .ink: "Hand-drawn pen and ink, spare irregular contour lines with broad flat color washes, like an illustrated field guide."
        case .watercolor: "Loose transparent watercolor, broad pigment washes, soft bleeding edges and a few decisive brush strokes."
        case .risograph: "Two-dimensional risograph print, overlapping spot-color fields, coarse halftone grain and deliberately simple forms."
        case .mosaic: "Flat graphic mosaic, large irregular colored tiles, clear grout lines and bold simplified shapes."
        case .contour: "Flat topographic illustration, flowing contour lines around broad colored landforms, sparse editorial map symbols."
        case .collage: "Two-dimensional torn-paper collage, large flat overlapping shapes, rough cut edges and minimal texture."
        }
    }

    var instructions: String {
        character + " No 3D render, miniature diorama, glossy surfaces, cinematic lighting, bevels, ambient occlusion, or decorative micro-detail. Use confident imperfect marks and generous simple shapes."
    }
}

/// Automatic assignments are separate from overrides so resetting restores the original medium.
@MainActor final class ProjectMapStyles: ObservableObject {
    static let shared = ProjectMapStyles()
    private let defaults: UserDefaults
    @Published private var automatic: [String: ProjectMapStyle]
    @Published private var overrides: [String: ProjectMapStyle]
    private static let automaticKey = "projectMapAutomaticStyles"
    private static let overridesKey = "projectMapStyleOverrides"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automatic = (defaults.dictionary(forKey: Self.automaticKey) ?? [:]).compactMapValues { ($0 as? String).flatMap(ProjectMapStyle.init(rawValue:)) }
        overrides = (defaults.dictionary(forKey: Self.overridesKey) ?? [:]).compactMapValues { ($0 as? String).flatMap(ProjectMapStyle.init(rawValue:)) }
    }

    func register(_ paths: [String]) {
        var updated = automatic
        for path in Set(paths).sorted() where updated[path] == nil {
            let counts = Dictionary(grouping: updated.values, by: { $0 }).mapValues(\.count)
            let minimum = ProjectMapStyle.allCases.map { counts[$0, default: 0] }.min() ?? 0
            let candidates = ProjectMapStyle.allCases.filter { counts[$0, default: 0] == minimum }
            updated[path] = candidates[Self.seed(path) % candidates.count]
        }
        guard updated != automatic else { return }
        automatic = updated
        defaults.set(updated.mapValues(\.rawValue), forKey: Self.automaticKey)
    }

    func style(for path: String) -> ProjectMapStyle {
        overrides[path] ?? automaticStyle(for: path)
    }

    func automaticStyle(for path: String) -> ProjectMapStyle {
        automatic[path] ?? ProjectMapStyle.allCases[Self.seed(path) % ProjectMapStyle.allCases.count]
    }

    func override(for path: String) -> ProjectMapStyle? { overrides[path] }

    func setOverride(_ style: ProjectMapStyle?, for path: String) {
        register([path])
        overrides[path] = style
        defaults.set(overrides.mapValues(\.rawValue), forKey: Self.overridesKey)
    }

    private static func seed(_ path: String) -> Int {
        SHA256.hash(data: Data(path.utf8)).prefix(4).reduce(0) { ($0 << 8) | Int($1) }
    }
}
