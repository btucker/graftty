import Foundation

/// @spec REMOTE-7.2
/// RPC request shape on a `pane_control` channel. Tagged-union JSON.
public enum PaneControlRequest: Sendable, Equatable {
    case split(target: String, direction: SplitDirection)
    case close(target: String)
    case swap(source: String, target: String)
    case equalize(target: String)
    case resize(
        target: String,
        direction: SplitDirection,
        amount: UInt16,
        viewportExtent: UInt32? = nil
    )

    public enum SplitDirection: String, Sendable, CaseIterable {
        case right
        case down
        case left
        case up
    }
}

public extension PaneControlRequest {
    /// Rebase an intent captured against the pane focused before a split
    /// onto the exact pane that split created. This keeps commands queued
    /// behind an asynchronous split in the same order and on the same
    /// logical focus target as local synchronous pane commands.
    func rebasingTarget(from oldTarget: String, to newTarget: String) -> Self {
        func rebase(_ target: String) -> String {
            target == oldTarget ? newTarget : target
        }

        switch self {
        case let .split(target, direction):
            return .split(target: rebase(target), direction: direction)
        case .close(let target):
            return .close(target: rebase(target))
        case let .swap(source, target):
            return .swap(
                source: rebase(source),
                target: rebase(target)
            )
        case .equalize(let target):
            return .equalize(target: rebase(target))
        case let .resize(target, direction, amount, viewportExtent):
            return .resize(
                target: rebase(target),
                direction: direction,
                amount: amount,
                viewportExtent: viewportExtent
            )
        }
    }
}

/// Projected focus fallback for close intents queued before earlier remote
/// pane mutations have completed. It mirrors the viewer's ordered leaf
/// fallback closely enough to keep repeated closes targeting live panes.
public struct PaneCloseProjection: Sendable, Equatable {
    public private(set) var target: String
    private var replacementCandidates: [String]

    public init(target: String, sessionOrder: [String]) {
        self.target = target
        self.replacementCandidates = sessionOrder
    }

    public var replacementTarget: String? {
        replacementCandidates.first { $0 != target }
    }

    public var sessionOrder: [String] {
        replacementCandidates
    }

    public static func sessionOrder(
        _ sessionOrder: [String],
        afterSplitting source: String,
        created: String,
        direction: PaneControlRequest.SplitDirection
    ) -> [String] {
        var result = sessionOrder.filter { $0 != created }
        guard let sourceIndex = result.firstIndex(of: source) else {
            result.append(created)
            return result
        }
        let insertionIndex: Int
        switch direction {
        case .left, .up:
            insertionIndex = sourceIndex
        case .right, .down:
            insertionIndex = sourceIndex + 1
        }
        result.insert(created, at: insertionIndex)
        return result
    }

    public mutating func projectSplit(
        from oldTarget: String,
        to createdTarget: String,
        direction: PaneControlRequest.SplitDirection,
        inheritsFocus: Bool
    ) {
        replacementCandidates = Self.sessionOrder(
            replacementCandidates,
            afterSplitting: oldTarget,
            created: createdTarget,
            direction: direction
        )
        if inheritsFocus, target == oldTarget {
            target = createdTarget
        }
    }

    public mutating func projectClose(
        from closedTarget: String,
        to replacementTarget: String?,
        inheritsFocus: Bool
    ) {
        replacementCandidates.removeAll { $0 == closedTarget }
        if inheritsFocus,
           target == closedTarget,
           let replacementTarget {
            target = replacementTarget
        }
    }
}

extension PaneControlRequest.SplitDirection: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        switch raw {
        case "right":
            self = .right
        case "down":
            self = .down
        case "left":
            self = .left
        case "up":
            self = .up
        case "horizontal":
            self = .right
        case "vertical":
            self = .down
        default:
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "unknown PaneControlRequest.SplitDirection: \(raw)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        // Hosts running released builds only decode the legacy
        // horizontal/vertical tokens, so right/down must keep encoding as
        // those for splits to work against not-yet-upgraded hosts. left/up
        // never existed on the old wire and use their semantic tokens.
        switch self {
        case .right:
            try c.encode("horizontal")
        case .down:
            try c.encode("vertical")
        case .left, .up:
            try c.encode(rawValue)
        }
    }
}

extension PaneControlRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, target, direction, source, amount, viewportExtent
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
        case .equalize(let target):
            try c.encode("equalize", forKey: .type)
            try c.encode(target, forKey: .target)
        case let .resize(target, direction, amount, viewportExtent):
            try c.encode("resize", forKey: .type)
            try c.encode(target, forKey: .target)
            try c.encode(direction, forKey: .direction)
            try c.encode(amount, forKey: .amount)
            try c.encodeIfPresent(
                viewportExtent,
                forKey: .viewportExtent
            )
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
        case "equalize":
            self = .equalize(target: try c.decode(String.self, forKey: .target))
        case "resize":
            self = .resize(
                target: try c.decode(String.self, forKey: .target),
                direction: try c.decode(SplitDirection.self, forKey: .direction),
                amount: try c.decode(UInt16.self, forKey: .amount),
                viewportExtent: try c.decodeIfPresent(
                    UInt32.self,
                    forKey: .viewportExtent
                )
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
    /// Successful split response from hosts that can identify the pane they
    /// created. Older peers decode this as `.ok` because the wire still uses
    /// `"ok": true`; newer viewers use the session name to correlate focus
    /// with the exact mutation instead of guessing from snapshot order.
    case splitCreated(sessionName: String)
    case error(code: String, message: String)

    public var isSuccess: Bool {
        switch self {
        case .ok, .splitCreated:
            true
        case .error:
            false
        }
    }
}

extension PaneControlResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case ok, error, code, message, createdSessionName
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try c.encode(true, forKey: .ok)
        case .splitCreated(let sessionName):
            try c.encode(true, forKey: .ok)
            try c.encode(sessionName, forKey: .createdSessionName)
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
            if let sessionName = try c.decodeIfPresent(
                String.self,
                forKey: .createdSessionName
            ) {
                self = .splitCreated(sessionName: sessionName)
            } else {
                self = .ok
            }
        } else {
            let code = try c.decode(String.self, forKey: .code)
            let message = try c.decode(String.self, forKey: .message)
            self = .error(code: code, message: message)
        }
    }
}
