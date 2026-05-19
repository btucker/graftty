import Foundation

/// @spec REMOTE-7.2
/// RPC request shape on a `pane_control` channel. Tagged-union JSON.
public enum PaneControlRequest: Sendable, Equatable {
    case split(target: String, direction: SplitDirection)
    case close(target: String)
    case swap(source: String, target: String)

    public enum SplitDirection: String, Codable, Sendable, CaseIterable {
        case horizontal
        case vertical
    }
}

extension PaneControlRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, target, direction, source
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .split(let target, let direction):
            try c.encode("split", forKey: .type)
            try c.encode(target, forKey: .target)
            try c.encode(direction, forKey: .direction)
        case .close(let target):
            try c.encode("close", forKey: .type)
            try c.encode(target, forKey: .target)
        case .swap(let source, let target):
            try c.encode("swap", forKey: .type)
            try c.encode(source, forKey: .source)
            try c.encode(target, forKey: .target)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "split":
            self = .split(
                target: try c.decode(String.self, forKey: .target),
                direction: try c.decode(SplitDirection.self, forKey: .direction)
            )
        case "close":
            self = .close(target: try c.decode(String.self, forKey: .target))
        case "swap":
            self = .swap(
                source: try c.decode(String.self, forKey: .source),
                target: try c.decode(String.self, forKey: .target)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "unknown PaneControlRequest type: \(type)"
            )
        }
    }
}

/// @spec REMOTE-7.3
/// RPC response shape. Reply to every `PaneControlRequest`. Errors
/// carry a short `code` (e.g. `"conflict"`, `"unknown-target"`) plus a
/// human message.
public enum PaneControlResponse: Sendable, Equatable {
    case ok
    case error(code: String, message: String)
}

extension PaneControlResponse: Codable {
    private enum CodingKeys: String, CodingKey { case ok, error, code, message }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try c.encode(true, forKey: .ok)
        case .error(let code, let message):
            try c.encode(false, forKey: .ok)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ok = try c.decode(Bool.self, forKey: .ok)
        if ok {
            self = .ok
        } else {
            let code = try c.decode(String.self, forKey: .code)
            let message = try c.decode(String.self, forKey: .message)
            self = .error(code: code, message: message)
        }
    }
}
