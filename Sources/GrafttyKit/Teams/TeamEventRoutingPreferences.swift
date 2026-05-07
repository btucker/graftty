import Foundation

/// Set of recipient classes for a single matrix row, encoded as bit flags so
/// each row's value is one of 0–7 (any combination of root / worktree / others).
public struct RecipientSet: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The repo's root worktree (the team's lead).
    public static let root           = RecipientSet(rawValue: 1 << 0)
    /// The worktree the event is *about*.
    public static let worktree       = RecipientSet(rawValue: 1 << 1)
    /// All other coworkers in the same repo.
    public static let otherWorktrees = RecipientSet(rawValue: 1 << 2)
}

/// User-configurable team event routing matrix for the routable team
/// events (TEAM-1.8). Each field is a `RecipientSet` controlling which
/// recipient classes the corresponding event type fans out to.
///
/// **Codable / RawRepresentable interaction:** this type adopts both protocols
/// (Codable for JSON, RawRepresentable<String> for `@AppStorage`). When the
/// same type adopts both, Swift's *synthesized* Codable encodes via
/// `rawValue` — and `rawValue` itself calls `JSONEncoder().encode(self)`, so
/// the synthesized form recurses infinitely until the stack overflows
/// (manifests as SIGBUS in `swift test`'s helper). To break the cycle, this
/// type provides **explicit** field-by-field Codable conformance via
/// `CodingKeys` + `init(from:)` + `encode(to:)`. JSON encoding never
/// round-trips through `rawValue`.
public struct TeamEventRoutingPreferences: Sendable {
    public var prStateChanged: RecipientSet
    public var prMerged: RecipientSet
    public var ciConclusionChanged: RecipientSet
    public var mergabilityChanged: RecipientSet

    public init(
        prStateChanged: RecipientSet = .worktree,
        prMerged: RecipientSet = .root,
        ciConclusionChanged: RecipientSet = .worktree,
        mergabilityChanged: RecipientSet = .worktree
    ) {
        self.prStateChanged = prStateChanged
        self.prMerged = prMerged
        self.ciConclusionChanged = ciConclusionChanged
        self.mergabilityChanged = mergabilityChanged
    }
}

extension TeamEventRoutingPreferences: Equatable {
    public static func == (lhs: TeamEventRoutingPreferences, rhs: TeamEventRoutingPreferences) -> Bool {
        lhs.prStateChanged == rhs.prStateChanged
            && lhs.prMerged == rhs.prMerged
            && lhs.ciConclusionChanged == rhs.ciConclusionChanged
            && lhs.mergabilityChanged == rhs.mergabilityChanged
    }
}

// MARK: - Codable (explicit, to avoid RawRepresentable recursion — see type doc)

extension TeamEventRoutingPreferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case prStateChanged
        case prMerged
        case ciConclusionChanged
        case mergabilityChanged
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            prStateChanged:      try c.decodeIfPresent(RecipientSet.self, forKey: .prStateChanged)      ?? .worktree,
            prMerged:            try c.decodeIfPresent(RecipientSet.self, forKey: .prMerged)            ?? .root,
            ciConclusionChanged: try c.decodeIfPresent(RecipientSet.self, forKey: .ciConclusionChanged) ?? .worktree,
            mergabilityChanged:  try c.decodeIfPresent(RecipientSet.self, forKey: .mergabilityChanged)  ?? .worktree
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(prStateChanged,      forKey: .prStateChanged)
        try c.encode(prMerged,            forKey: .prMerged)
        try c.encode(ciConclusionChanged, forKey: .ciConclusionChanged)
        try c.encode(mergabilityChanged,  forKey: .mergabilityChanged)
    }
}

// MARK: - @AppStorage adapter

/// `@AppStorage` accepts `RawRepresentable` whose raw type is `String`, `Int`,
/// etc. This adapter wraps the JSON encoding so the struct can be persisted
/// directly: `@AppStorage("teamEventRoutingPreferences") var prefs = TeamEventRoutingPreferences()`.
extension TeamEventRoutingPreferences: RawRepresentable {
    public init?(rawValue: String) {
        guard let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(TeamEventRoutingPreferences.self, from: data)
        else { return nil }
        self = decoded
    }

    public var rawValue: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8)
        else { return "{}" }
        return string
    }
}
