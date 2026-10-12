import Foundation

/// Typed commands only. CDP method names, sockets and profile paths stay on the host.
public enum ChromeTabAction: Codable, Equatable, Sendable {
    case list
    case launch(url: String)
    case launchOffer(id: UUID, url: String)
    case select(tabID: String)
    case frame(tabID: String)
    case tap(tabID: String, x: Double, y: Double)
    case scroll(tabID: String, x: Double, y: Double, deltaX: Double, deltaY: Double)
    case text(tabID: String, text: String)
    case key(tabID: String, key: ChromeTabKey)

    public var tabID: String? {
        switch self {
        case .list, .launch, .launchOffer: return nil
        case .select(let id), .frame(let id), .tap(let id, _, _), .scroll(let id, _, _, _, _), .text(let id, _), .key(let id, _): return id
        }
    }

    public var isValid: Bool {
        if let tabID, tabID.isEmpty || tabID.utf8.count > 128 { return false }
        func point(_ x: Double, _ y: Double) -> Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
        switch self {
        case .launch(let raw), .launchOffer(_, let raw):
            guard raw.utf8.count <= 8192, let url = URL(string: raw), let host = url.host, !host.isEmpty else { return false }
            return ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.user == nil && url.password == nil
        case .tap(_, let x, let y): return point(x, y)
        case .scroll(_, let x, let y, let dx, let dy): return point(x, y) && dx.isFinite && dy.isFinite && abs(dx) <= 2000 && abs(dy) <= 2000
        case .text(_, let text): return text.utf8.count <= 4096
        default: return true
        }
    }
}

public enum ChromeTabKey: String, Codable, Equatable, Sendable { case enter, tab, backspace, escape }

public struct ChromeTabRequest: Codable, Equatable, Sendable {
    public var target: String
    public var action: ChromeTabAction
    public init(target: String, action: ChromeTabAction) { self.target = target; self.action = action }
    public static let maximumRequestBytes = 16 * 1024
    public static let maximumResponseBytes = 1024 * 1024
}

public struct ChromeTab: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var url: String
    public init(id: String, title: String, url: String) { self.id = id; self.title = title; self.url = url }
}

public struct ChromeTabFrame: Codable, Equatable, Sendable {
    public var tabID: String
    public var jpeg: Data
    public var sequence: UInt64
    public init(tabID: String, jpeg: Data, sequence: UInt64) { self.tabID = tabID; self.jpeg = jpeg; self.sequence = sequence }
    public static let maximumJPEGBytes = 512 * 1024
    public static let viewportWidth = 1024
    public static let viewportHeight = 768
}

public struct ChromeTabState: Codable, Equatable, Sendable {
    public var tabs: [ChromeTab]
    public var selectedTabID: String?
    public var frame: ChromeTabFrame?
    public init(tabs: [ChromeTab] = [], selectedTabID: String? = nil, frame: ChromeTabFrame? = nil) {
        self.tabs = tabs; self.selectedTabID = selectedTabID; self.frame = frame
    }
}

public struct ChromeTabResponse: Codable, Equatable, Sendable {
    public var state: ChromeTabState?
    public var error: String?
    public init(state: ChromeTabState? = nil, error: String? = nil) { self.state = state; self.error = error }

    /// Base64 JPEGs can contain many slashes. Escaping each slash doubles wire size.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
