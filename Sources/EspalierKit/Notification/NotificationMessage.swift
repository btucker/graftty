import Foundation

public enum NotificationMessage: Sendable {
    case notify(path: String, text: String, clearAfter: TimeInterval? = nil)
    case clear(path: String)
    case listPanes(path: String)
    case addPane(path: String, direction: PaneSplitWire, command: String?)
    case closePane(path: String, index: Int)
}

extension NotificationMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, path, text, clearAfter, direction, command, index
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notify(let path, let text, let clearAfter):
            try container.encode("notify", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(clearAfter, forKey: .clearAfter)
        case .clear(let path):
            try container.encode("clear", forKey: .type)
            try container.encode(path, forKey: .path)
        case .listPanes(let path):
            try container.encode("list_panes", forKey: .type)
            try container.encode(path, forKey: .path)
        case .addPane(let path, let direction, let command):
            try container.encode("add_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(direction, forKey: .direction)
            try container.encodeIfPresent(command, forKey: .command)
        case .closePane(let path, let index):
            try container.encode("close_pane", forKey: .type)
            try container.encode(path, forKey: .path)
            try container.encode(index, forKey: .index)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "notify":
            let path = try container.decode(String.self, forKey: .path)
            let text = try container.decode(String.self, forKey: .text)
            let clearAfter = try container.decodeIfPresent(TimeInterval.self, forKey: .clearAfter)
            self = .notify(path: path, text: text, clearAfter: clearAfter)
        case "clear":
            let path = try container.decode(String.self, forKey: .path)
            self = .clear(path: path)
        case "list_panes":
            let path = try container.decode(String.self, forKey: .path)
            self = .listPanes(path: path)
        case "add_pane":
            let path = try container.decode(String.self, forKey: .path)
            let direction = try container.decode(PaneSplitWire.self, forKey: .direction)
            let command = try container.decodeIfPresent(String.self, forKey: .command)
            self = .addPane(path: path, direction: direction, command: command)
        case "close_pane":
            let path = try container.decode(String.self, forKey: .path)
            let index = try container.decode(Int.self, forKey: .index)
            self = .closePane(path: path, index: index)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown message type: \(type)"))
        }
    }
}

/// Wire-level representation of a four-way pane split direction. Mirrors
/// the app-layer `PaneSplit` enum, but lives in EspalierKit so the CLI can
/// encode/decode it without importing app-layer code.
public enum PaneSplitWire: String, Codable, Sendable {
    case right, left, up, down
}

/// One row in the response to a `listPanes` request. `id` is the 1-based
/// pane number within the worktree's split tree (see design spec). `title`
/// is the pane's OSC-0/OSC-2-reported title if any, otherwise nil.
public struct PaneInfo: Codable, Sendable, Equatable {
    public let id: Int
    public let title: String?
    public let focused: Bool

    public init(id: Int, title: String?, focused: Bool) {
        self.id = id
        self.title = title
        self.focused = focused
    }
}

/// Reply sent from the app back to the CLI after a request-style
/// `NotificationMessage`. `ok` covers successful fire-and-forget commands;
/// `error` carries a human-readable message printed to the CLI's stderr;
/// `paneList` is the response to `listPanes`.
public enum ResponseMessage: Sendable, Equatable {
    case ok
    case error(String)
    case paneList([PaneInfo])
}

extension ResponseMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, message, panes
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode("ok", forKey: .type)
        case .error(let message):
            try container.encode("error", forKey: .type)
            try container.encode(message, forKey: .message)
        case .paneList(let panes):
            try container.encode("pane_list", forKey: .type)
            try container.encode(panes, forKey: .panes)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "ok":
            self = .ok
        case "error":
            let msg = try container.decode(String.self, forKey: .message)
            self = .error(msg)
        case "pane_list":
            let panes = try container.decode([PaneInfo].self, forKey: .panes)
            self = .paneList(panes)
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.type], debugDescription: "Unknown response type: \(type)"))
        }
    }
}
