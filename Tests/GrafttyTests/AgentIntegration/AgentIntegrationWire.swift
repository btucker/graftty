import Foundation
import CoreGraphics

/// Count chromatic glyph pixels on deliberately styled fixture rows. Row lookup
/// prevents unrelated chrome, links, or emoji from satisfying a syntax check.
enum AgentIntegrationColorProbe {
    static let markers = ["COLOR_INLINE", "COLOR_LINK", "COLOR_STRING", "COLOR_REMOVED", "COLOR_ADDED"]

    static func counts(image: CGImage, physicalRows: String, cellHeight: Int) -> [String: Int] {
        var result = Dictionary(uniqueKeysWithValues: markers.map { ($0, -1) })
        guard cellHeight > 0 else { return result }
        let rows = physicalRows.components(separatedBy: "\n")
        for marker in markers {
            for (row, text) in rows.enumerated() where text.contains(marker) {
                let y = row * cellHeight
                guard y + cellHeight <= image.height,
                      let crop = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: cellHeight)) else { continue }
                var rgba = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
                let pixels = rgba.withUnsafeMutableBytes { bytes -> Int? in
                    guard let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                        bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                    let values = bytes.bindMemory(to: UInt8.self)
                    var count = 0
                    for offset in stride(from: 0, to: values.count, by: 4) {
                        let r = Int(values[offset]), g = Int(values[offset + 1]), b = Int(values[offset + 2])
                        // The isolated fixtures use dark, neutral defaults.
                        // Exclude gray text, its antialiasing, and the background.
                        if max(r, g, b) - min(r, g, b) >= 40 { count += 1 }
                    }
                    return count
                }
                if let pixels { result[marker] = max(result[marker] ?? -1, pixels) }
            }
        }
        return result
    }
}

enum AgentIntegrationAnchor {
    static func first(in text: String) -> String {
        guard let range = text.range(of: "ROW-[0-9]{6}", options: .regularExpression) else { return "" }
        return String(text[range])
    }
}

/// Both native scroll containers use top-down document coordinates. Read the
/// physical rows that intersect their viewport, including partially visible rows.
enum AgentIntegrationViewport {
    static func visibleRows(_ text: String, frame: CGRect, viewport: CGRect, rowHeight: CGFloat) -> String {
        guard rowHeight.isFinite, rowHeight > 0, frame.intersects(viewport) else { return "" }
        let first = max(0, Int(floor((viewport.minY - frame.minY) / rowHeight)))
        let last = max(first, Int(ceil((min(viewport.maxY, frame.maxY) - frame.minY) / rowHeight)))
        return text.components(separatedBy: "\n").dropFirst(first).prefix(last - first).joined(separator: "\n")
    }
}

/// Shared only by the Mac test bundle and the mobile interaction host.
struct AgentIntegrationCommand: Codable, Equatable, Sendable {
    let id: Int
    let operation: String
    var provider: String = ""
    var parameters: [String: String] = [:]

    var isSupported: Bool {
        ["idle", "start", "snapshot", "resize", "takeControl", "scroll", "select", "reconnect",
         "connect", "acceptOffer", "roster", "message", "input", "keyboard", "visibility", "recreate", "verify", "finish"].contains(operation)
    }
}

struct AgentIntegrationObservation: Codable, Equatable, Sendable {
    let id: Int
    let client: String
    let provider: String
    let values: [String: String]
    let error: String?
}

struct AgentIntegrationError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct AgentIntegrationManifest: Codable, Sendable {
    let endpoint: URL
    let root: String
    let cli: String
    let zmx: String
    let codex: String
    let claude: String
    let seed: UInt64
}

/// The controller owns the queue. A native client never invents a pass locally.
struct AgentIntegrationTransport: Sendable {
    let endpoint: URL
    let client: String

    func request(_ path: String, body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.timeoutInterval = 30
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw AgentIntegrationError("integration controller rejected \(path): \(String(decoding: data, as: UTF8.self))")
        }
        return data
    }

    func register(_ values: [String: String]) async throws {
        _ = try await request("register/\(client)", body: JSONEncoder().encode(values))
    }

    @MainActor
    func run(handle: (AgentIntegrationCommand) async throws -> [String: String]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        while !Task.isCancelled, ContinuousClock.now < deadline {
            let data = try await request("commands/\(client)")
            let command = try JSONDecoder().decode(AgentIntegrationCommand.self, from: data)
            if command.operation == "idle" { continue }
            let result: AgentIntegrationObservation
            do {
                guard command.isSupported else { throw AgentIntegrationError("unsupported action \(command.operation)") }
                let values = try await handle(command)
                result = .init(id: command.id, client: client, provider: command.provider, values: values, error: nil)
            } catch {
                result = .init(id: command.id, client: client, provider: command.provider, values: [:], error: String(describing: error))
            }
            _ = try await request("observations/\(client)", body: JSONEncoder().encode(result))
            if command.operation == "finish" { return }
        }
        throw AgentIntegrationError("integration controller did not finish within 15 minutes")
    }
}
