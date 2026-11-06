import Foundation

/// Sortable strings that always leave room between two neighbors, so moving a
/// row writes only that row. Compared as plain strings on every device.
public enum FractionalRank {
    private static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
    private static let values = Dictionary(uniqueKeysWithValues: digits.enumerated().map { ($1, $0) })
    private static let maximumLength = 512
    private static let seedSpacing = 1024

    /// Ranks are never empty and never end in the lowest digit, which keeps
    /// space below every rank. A peer's malformed rank is treated as no rank.
    public static func isValid(_ rank: String) -> Bool {
        let bytes = Array(rank.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumLength, bytes.last != digits[0] else { return false }
        return bytes.allSatisfy { values[$0] != nil }
    }

    /// Increasing ranks for a host's existing order, with space between them.
    public static func seed(index: Int) -> String {
        var value = (max(0, index) + 1) * seedSpacing
        var result = [UInt8](repeating: digits[0], count: 4)
        for position in result.indices.reversed() {
            result[position] = digits[value % digits.count]
            value /= digits.count
        }
        return String(decoding: result + [digits[31]], as: UTF8.self)
    }

    /// A rank above `lower` and below `upper`; nil means unbounded. Callers
    /// must resolve ties first: with `lower >= upper` the result only sorts
    /// after `lower`.
    public static func between(_ lower: String?, _ upper: String?) -> String {
        let low = Array((lower ?? "").utf8)
        let high = upper.map { Array($0.utf8) }
        if let high, !(low.lexicographicallyPrecedes(high)) {
            return String(decoding: midpoint(low, nil), as: UTF8.self)
        }
        return String(decoding: midpoint(low, high), as: UTF8.self)
    }

    private static func midpoint(_ low: [UInt8], _ high: [UInt8]?) -> [UInt8] {
        if let high {
            var shared = 0
            while shared < high.count, (shared < low.count ? low[shared] : digits[0]) == high[shared] { shared += 1 }
            if shared > 0 {
                return Array(high[..<shared]) + midpoint(Array(low.dropFirst(shared)), Array(high[shared...]))
            }
        }
        let lowDigit = low.first.flatMap { values[$0] } ?? 0
        let highDigit = high?.first.flatMap { values[$0] } ?? digits.count
        if highDigit - lowDigit > 1 {
            return [digits[(lowDigit + highDigit + 1) / 2]]
        }
        if let high, high.count > 1 { return [high[0]] }
        return [digits[lowDigit]] + midpoint(Array(low.dropFirst()), nil)
    }
}

/// Turns a drop into the rank writes that make it true on every device.
public enum RankPlacement {
    public struct Row: Sendable, Equatable {
        public var id: String
        public var rank: String?
        /// False for rows on hosts that are older or can't be reached.
        public var isWritable: Bool
        public init(id: String, rank: String?, isWritable: Bool = true) {
            self.id = id
            self.rank = rank.flatMap { FractionalRank.isValid($0) ? $0 : nil }
            self.isWritable = isWritable
        }
    }

    public struct Write: Sendable, Equatable {
        public var id: String
        public var rank: String
    }

    /// `rows` is the displayed order, including the moved row. `toIndex` is its
    /// position in the resulting list. Rows without a rank always sort last,
    /// so a row dropped below them lands just above them.
    public static func move(_ id: String, toIndex: Int, in rows: [Row]) -> [Write] {
        guard let source = rows.firstIndex(where: { $0.id == id }), source != toIndex else { return [] }
        let rest = rows.filter { $0.id != id }
        let ranked = rest.prefix { $0.rank != nil }
        let index = min(max(0, toIndex), ranked.count)
        let lower = index > 0 ? ranked[index - 1].rank : nil
        let upper = index < ranked.count ? ranked[index].rank : nil
        guard let lower, let upper, lower >= upper else {
            return [Write(id: id, rank: FractionalRank.between(lower, upper))]
        }
        // The lower neighbor keeps its rank; push the tied run above the
        // moved row, staying under the first rank past the tie.
        var run: [Row] = []
        var next: String?
        for row in ranked[index...] {
            if let rank = row.rank, rank > lower { next = rank; break }
            run.append(row)
        }
        var previous = FractionalRank.between(lower, next)
        var writes = [Write(id: id, rank: previous)]
        for row in run where row.isWritable {
            previous = FractionalRank.between(previous, next)
            writes.append(Write(id: row.id, rank: previous))
        }
        return writes
    }
}
