import Foundation

public struct DisplayClientID: Sendable, Hashable, Codable, Equatable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum DisplayClientKind: String, Sendable, Hashable, Codable {
    case mac
    case web
    case ios
    case preview
}

public enum DisplayClientRole: String, Sendable, Hashable, Codable {
    case interactive
    case preview
}

public struct DisplayGrid: Sendable, Hashable, Codable {
    public enum ValidationError: Error, Equatable {
        case invalidDimension
    }

    public static let daemonFallback = DisplayGrid(validatedCols: 80, rows: 24)

    public let cols: UInt16
    public let rows: UInt16

    public init(cols: UInt16, rows: UInt16) throws {
        guard cols > 0, rows > 0 else {
            throw ValidationError.invalidDimension
        }
        self.cols = cols
        self.rows = rows
    }

    private init(validatedCols cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let cols = try container.decode(UInt16.self, forKey: .cols)
        let rows = try container.decode(UInt16.self, forKey: .rows)
        try self.init(cols: cols, rows: rows)
    }
}

public struct DisplayOwnershipSnapshot: Sendable, Hashable, Codable {
    public enum ValidationError: Error, Equatable {
        case inconsistentOwnerFields
    }

    public let sessionName: String
    public let ownerClientID: DisplayClientID?
    public let ownerKind: DisplayClientKind?
    public let grid: DisplayGrid
    public let epoch: UInt64
    /// Monotonic per-session revision that advances on EVERY store mutation,
    /// including same-epoch owner resizes (which change the grid without bumping
    /// `epoch`).  Followers reject any snapshot whose `revision` is lower than the
    /// last one they applied, so a reordered/superseded delivery cannot roll the
    /// display back to a stale grid — the ordering signal `epoch` alone cannot
    /// provide within a single ownership tenure.
    public let revision: UInt64

    public var ownerless: Bool { ownerClientID == nil }
    public var isOwnerless: Bool { ownerless }

    public init(
        sessionName: String,
        ownerClientID: DisplayClientID?,
        ownerKind: DisplayClientKind?,
        grid: DisplayGrid,
        epoch: UInt64,
        revision: UInt64 = 0
    ) throws {
        guard (ownerClientID == nil) == (ownerKind == nil) else {
            throw ValidationError.inconsistentOwnerFields
        }
        self.sessionName = sessionName
        self.ownerClientID = ownerClientID
        self.ownerKind = ownerKind
        self.grid = grid
        self.epoch = epoch
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey {
        case sessionName
        case ownerClientID
        case ownerKind
        case grid
        case epoch
        case revision
        case ownerless
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            sessionName: try container.decode(String.self, forKey: .sessionName),
            ownerClientID: try container.decodeIfPresent(DisplayClientID.self, forKey: .ownerClientID),
            ownerKind: try container.decodeIfPresent(DisplayClientKind.self, forKey: .ownerKind),
            grid: try container.decode(DisplayGrid.self, forKey: .grid),
            epoch: try container.decode(UInt64.self, forKey: .epoch),
            // Backward compatible with wire messages predating the revision field.
            revision: try container.decodeIfPresent(UInt64.self, forKey: .revision) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionName, forKey: .sessionName)
        try container.encodeIfPresent(ownerClientID, forKey: .ownerClientID)
        try container.encodeIfPresent(ownerKind, forKey: .ownerKind)
        try container.encode(grid, forKey: .grid)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(revision, forKey: .revision)
        try container.encode(ownerless, forKey: .ownerless)
    }
}
