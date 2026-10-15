import Foundation
import CoreGraphics
import GhosttyTerminal
import GrafttyProtocol

@MainActor
enum TerminalLinkResolver {
    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    static func webURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              ChromeTabAction.launch(url: value).isValid else { return nil }
        return url
    }

    /// The native gesture supplies an anchor obtained by reading a suffix from
    /// actual terminal cells. Require the entire anchor to belong to one URL.
    static func url(in text: String, anchor: NSRange?) -> URL? {
        guard let anchor, anchor.location != NSNotFound, anchor.length > 0,
              anchor.location <= text.utf16.count,
              anchor.length <= text.utf16.count - anchor.location else { return nil }
        let matches = detector?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
        guard let match = matches.first(where: {
            $0.range.location <= anchor.location && NSMaxRange($0.range) >= NSMaxRange(anchor)
        }) else { return nil }
        return webURL(match.url?.absoluteString)
    }

    /// Viewport reads join soft-wrapped rows. Rebuild ASCII cell positions
    /// instead of trusting the upstream word range, which counts hard lines
    /// as screen rows. Unicode cell widths and hidden padding origins are not
    /// public API: reject uncertain text and require every possible padded
    /// cell under the press to belong to the same URL.
    static func url(
        in text: String, at point: CGPoint, grid: TerminalGridMetrics,
        displayScale: CGFloat
    ) -> URL? {
        guard displayScale.isFinite, displayScale > 0 else { return nil }
        func cells(_ position: CGFloat, pixels: UInt32, count: UInt16, cell: UInt32) -> ClosedRange<Int>? {
            let position = position * displayScale
            let extent = Double(pixels)
            let cellSize = Double(cell)
            let padding = extent - Double(count) * cellSize
            guard position.isFinite, position >= 0, position < extent,
                  count > 0, cell > 0, padding >= 0 else { return nil }
            let first = Int(floor((position - padding) / cellSize))
            let last = Int(floor(position / cellSize))
            guard first >= 0, last < Int(count), first <= last else { return nil }
            return first...last
        }
        guard let rows = cells(point.y, pixels: grid.heightPixels, count: grid.rows, cell: grid.cellHeightPixels),
              let columns = cells(point.x, pixels: grid.widthPixels, count: grid.columns, cell: grid.cellWidthPixels)
        else { return nil }
        let matches = detector?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
        let width = Int(grid.columns)
        var row = 0
        var offset = 0
        var target: NSTextCheckingResult?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
            let length = line.utf8.count
            let lineRows = max(1, (length + width - 1) / width)
            let firstRow = max(row, rows.lowerBound)
            let lastRow = min(row + lineRows - 1, rows.upperBound)
            if firstRow <= lastRow {
                let first = (firstRow - row) * width + columns.lowerBound
                let last = (lastRow - row) * width + columns.upperBound
                guard last < length,
                      let match = matches.first(where: {
                          $0.range.location <= offset + first
                              && NSMaxRange($0.range) > offset + last
                      }), target == nil || target?.range == match.range
                else { return nil }
                target = match
            }
            row += lineRows
            if row > rows.upperBound { return webURL(target?.url?.absoluteString) }
            offset += length + 1
        }
        return nil
    }
}
