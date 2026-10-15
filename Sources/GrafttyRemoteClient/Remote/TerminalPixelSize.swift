import Foundation

/// IOS-4.43: the terminal pixel size an owner reports with `ownerResize`, in
/// the kernel's `struct winsize` units (`ws_xpixel`/`ws_ypixel`). Zero means
/// unspecified (REMOTE-9.12).
public struct TerminalPixelSize: Equatable, Sendable {
    public var width: UInt16
    public var height: UInt16

    public static let unspecified = TerminalPixelSize(width: 0, height: 0)

    public init(width: UInt16, height: UInt16) {
        self.width = width
        self.height = height
    }

    /// Derive the grid's pixel extent from the renderer's viewport. Each axis
    /// uses `cells × cell pixels` when the cell size is known, so a program
    /// dividing by the grid recovers the true cell size; otherwise it falls
    /// back to the view's pixel size. Values clamp to `UInt16`.
    public init(
        cols: UInt16,
        rows: UInt16,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32,
        widthPixels: UInt32,
        heightPixels: UInt32
    ) {
        func axis(_ cells: UInt16, _ cell: UInt32, _ view: UInt32) -> UInt16 {
            let total = cell > 0 ? UInt64(cells) * UInt64(cell) : UInt64(view)
            return UInt16(clamping: total)
        }
        self.init(
            width: axis(cols, cellWidthPixels, widthPixels),
            height: axis(rows, cellHeightPixels, heightPixels)
        )
    }
}
