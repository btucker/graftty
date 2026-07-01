import Foundation

/// A control event sent from the web client as a WebSocket *text*
/// frame. Binary frames carry raw PTY bytes; this shape is for
/// everything else.
///
public enum WebControlEnvelope: Equatable {
    private static let maxGridDimension = 10_000

    /// Client → server legacy resize. Kept during ownership migration so older
    /// clients fail soft while owner-aware clients move to `.ownerResize`.
    case resize(cols: UInt16, rows: UInt16)

    /// Server → client. "The PTY's current dimensions are these." Sent on
    /// WebSocket open and again whenever the server observes a size
    /// change (e.g. a sibling client resized via its own `resize` frame).
    /// Clients use this to size their rendering frame so a wider-than-
    /// screen server grid can be scrolled horizontally on a phone while
    /// the Mac pane holds its original width.
    case grid(cols: UInt16, rows: UInt16)
    case hello(
        clientID: DisplayClientID,
        kind: DisplayClientKind,
        role: DisplayClientRole,
        visible: Bool,
        cols: UInt16,
        rows: UInt16
    )
    case takeControl(clientID: DisplayClientID, kind: DisplayClientKind, cols: UInt16, rows: UInt16)
    case ownerResize(clientID: DisplayClientID, epoch: UInt64, cols: UInt16, rows: UInt16)
    case ownership(DisplayOwnershipSnapshot)

    public enum ParseError: Error, Equatable {
        case notJSON
        case unknownType(String)
        case missingField(String)
        case invalidField(String)
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
            let grid = try parseGrid(dict)
            return .resize(cols: grid.cols, rows: grid.rows)
        case "grid":
            let grid = try parseGrid(dict)
            return .grid(cols: grid.cols, rows: grid.rows)
        case "hello":
            let clientID = try parseClientID(dict)
            let kind = try parseKind(dict)
            let role = try parseRole(dict)
            guard let visible = dict["visible"] as? Bool else { throw ParseError.missingField("visible") }
            let grid = try parseGrid(dict)
            return .hello(
                clientID: clientID,
                kind: kind,
                role: role,
                visible: visible,
                cols: grid.cols,
                rows: grid.rows
            )
        case "takeControl":
            let clientID = try parseClientID(dict)
            let kind = try parseKind(dict)
            let grid = try parseGrid(dict)
            return .takeControl(clientID: clientID, kind: kind, cols: grid.cols, rows: grid.rows)
        case "ownerResize":
            let clientID = try parseClientID(dict)
            let epoch = try parseEpoch(dict)
            let grid = try parseGrid(dict)
            return .ownerResize(clientID: clientID, epoch: epoch, cols: grid.cols, rows: grid.rows)
        case "ownership":
            guard let snapshotObject = dict["snapshot"] else { throw ParseError.missingField("snapshot") }
            guard JSONSerialization.isValidJSONObject(snapshotObject) else {
                throw ParseError.invalidField("snapshot")
            }
            let snapshotData = try JSONSerialization.data(withJSONObject: snapshotObject)
            do {
                let snapshot = try JSONDecoder().decode(DisplayOwnershipSnapshot.self, from: snapshotData)
                guard snapshot.grid.cols <= maxGridDimension, snapshot.grid.rows <= maxGridDimension else {
                    throw ParseError.invalidDimension
                }
                return .ownership(snapshot)
            } catch DisplayGrid.ValidationError.invalidDimension {
                throw ParseError.invalidDimension
            } catch ParseError.invalidDimension {
                throw ParseError.invalidDimension
            } catch {
                throw ParseError.invalidField("snapshot")
            }
        default:
            throw ParseError.unknownType(type)
        }
    }

    /// Serialize to the JSON text shape a server-side parser expects.
    /// Kept adjacent to `parse` so renaming a field updates both directions.
    public func encoded() -> String {
        switch self {
        case let .resize(cols, rows):
            return Self.encodeObject(["cols": cols, "rows": rows, "type": "resize"])
        case let .grid(cols, rows):
            return Self.encodeObject(["cols": cols, "rows": rows, "type": "grid"])
        case let .hello(clientID, kind, role, visible, cols, rows):
            return Self.encodeObject([
                "clientID": clientID.rawValue,
                "cols": cols,
                "kind": kind.rawValue,
                "role": role.rawValue,
                "rows": rows,
                "type": "hello",
                "visible": visible,
            ])
        case let .takeControl(clientID, kind, cols, rows):
            return Self.encodeObject([
                "clientID": clientID.rawValue,
                "cols": cols,
                "kind": kind.rawValue,
                "rows": rows,
                "type": "takeControl",
            ])
        case let .ownerResize(clientID, epoch, cols, rows):
            return Self.encodeObject([
                "clientID": clientID.rawValue,
                "cols": cols,
                "epoch": epoch,
                "rows": rows,
                "type": "ownerResize",
            ])
        case let .ownership(snapshot):
            let snapshotData = try! JSONEncoder().encode(snapshot)
            let snapshotObject = try! JSONSerialization.jsonObject(with: snapshotData)
            return Self.encodeObject(["snapshot": snapshotObject, "type": "ownership"])
        }
    }

    private static func parseClientID(_ dict: [String: Any]) throws -> DisplayClientID {
        guard let rawValue = dict["clientID"] as? String else { throw ParseError.missingField("clientID") }
        return DisplayClientID(rawValue)
    }

    private static func parseKind(_ dict: [String: Any]) throws -> DisplayClientKind {
        guard let rawValue = dict["kind"] as? String else { throw ParseError.missingField("kind") }
        guard let kind = DisplayClientKind(rawValue: rawValue) else { throw ParseError.invalidField("kind") }
        return kind
    }

    private static func parseRole(_ dict: [String: Any]) throws -> DisplayClientRole {
        guard let rawValue = dict["role"] as? String else { throw ParseError.missingField("role") }
        guard let role = DisplayClientRole(rawValue: rawValue) else { throw ParseError.invalidField("role") }
        return role
    }

    private static func parseGrid(_ dict: [String: Any]) throws -> DisplayGrid {
        guard let cols = dict["cols"] as? Int else { throw ParseError.missingField("cols") }
        guard let rows = dict["rows"] as? Int else { throw ParseError.missingField("rows") }
        guard cols > 0, rows > 0, cols <= maxGridDimension, rows <= maxGridDimension else {
            throw ParseError.invalidDimension
        }
        return try DisplayGrid(cols: UInt16(cols), rows: UInt16(rows))
    }

    private static func parseEpoch(_ dict: [String: Any]) throws -> UInt64 {
        guard let rawEpoch = dict["epoch"] else { throw ParseError.missingField("epoch") }
        guard let epoch = rawEpoch as? NSNumber, CFGetTypeID(epoch) != CFBooleanGetTypeID() else {
            throw ParseError.invalidField("epoch")
        }

        switch String(cString: epoch.objCType) {
        case "c", "s", "i", "l", "q":
            guard epoch.int64Value >= 0 else { throw ParseError.invalidField("epoch") }
            return UInt64(epoch.int64Value)
        case "C", "S", "I", "L", "Q":
            return epoch.uint64Value
        default:
            throw ParseError.invalidField("epoch")
        }
    }

    private static func encodeObject(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
