import Foundation

/// Decodes the one-time `zmx attach --replay-grid` preamble. A zero grid
/// explicitly identifies a daemon whose VT replay has no source metadata.
/// Unframed diagnostics and test-fixture output remain readable.
struct ZmxReplayGridDecoder {
    struct Grid: Equatable {
        let cols: UInt16
        let rows: UInt16
    }

    struct Output {
        var started = false
        var grid: Grid?
        var bytes = Data()
    }

    private static let magic = Data("GFTGRID1".utf8)
    private var pending = Data()
    private var finished = false

    mutating func consume(_ bytes: Data, endOfStream: Bool = false) -> Output {
        guard !finished else { return Output(bytes: bytes) }
        pending.append(bytes)
        let prefixCount = min(pending.count, Self.magic.count)
        let matches = pending.prefix(prefixCount) == Self.magic.prefix(prefixCount)
        if matches, pending.count < 12, !endOfStream { return Output() }
        finished = true
        defer { pending = Data() }
        guard matches, pending.count >= 12 else {
            return Output(started: true, bytes: pending)
        }
        let cols = UInt16(pending[8]) | UInt16(pending[9]) << 8
        let rows = UInt16(pending[10]) | UInt16(pending[11]) << 8
        let grid = cols > 0 && rows > 0 ? Grid(cols: cols, rows: rows) : nil
        return Output(started: true, grid: grid, bytes: Data(pending.dropFirst(12)))
    }
}
