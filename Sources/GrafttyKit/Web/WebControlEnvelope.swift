import Foundation

/// A control event sent from the web client as a WebSocket *text*
/// frame. Binary frames carry raw PTY bytes; this shape is for
/// everything else.
///
/// Phase 2 has exactly one variant (`.resize`). Keeping it as a
/// Swift enum rather than a looser dictionary lets us enforce
/// exhaustive handling when new variants arrive in Phase 3
/// (sessionList, ping, etc.).
public enum WebControlEnvelope: Equatable {
    case resize(cols: UInt16, rows: UInt16)

    public enum ParseError: Error, Equatable {
        case notJSON
        case unknownType(String)
        case missingField(String)
        case invalidDimension
    }

    public static func parse(_ data: Data) throws -> WebControlEnvelope {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ParseError.notJSON
        }
        guard let dict = json as? [String: Any] else { throw ParseError.notJSON }
        guard let type = dict["type"] as? String else { throw ParseError.missingField("type") }
        switch type {
        case "resize":
            guard let cols = dict["cols"] as? Int else { throw ParseError.missingField("cols") }
            guard let rows = dict["rows"] as? Int else { throw ParseError.missingField("rows") }
            guard cols > 0 && rows > 0 && cols <= 10_000 && rows <= 10_000 else {
                throw ParseError.invalidDimension
            }
            return .resize(cols: UInt16(cols), rows: UInt16(rows))
        default:
            throw ParseError.unknownType(type)
        }
    }
}
