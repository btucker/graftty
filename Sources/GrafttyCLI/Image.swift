import ArgumentParser
import CoreGraphics
import Darwin
import Foundation
import GrafttyKit
import ImageIO

/// `graftty image <path>`: draw an image inline in the pane that the
/// calling agent runs in, placed above a block of blank padding rows so a
/// TUI repainting its live bottom region lands on the padding instead.
struct Image: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Draw an image inline in this pane's terminal"
    )

    /// Rows the Claude Code / Codex live region occupies while a tool runs
    /// (spinner, tool call, input box); the image must sit above all of it.
    static let defaultPad = 12

    @Argument(help: "Path to a PNG, JPEG, HEIC, GIF, WebP, or PDF file.")
    var path: String

    @Option(name: .long, help: "Maximum width in terminal columns (defaults to the pane width).")
    var width: Int?

    @Option(name: .long, help: "Blank rows to reserve below the image for the TUI's live region.")
    var pad: Int = Image.defaultPad

    func run() throws {
        guard InlineImage.isGhosttyTerminal(environment: ProcessInfo.processInfo.environment) else {
            throw CLIEnv.fail("Terminal is not ghostty, so it cannot draw inline images; use `graftty open` instead.")
        }
        guard let ttyPath = InlineImage.findTerminal() else {
            throw CLIEnv.fail("No terminal found in this process tree.")
        }
        let fd = Darwin.open(ttyPath, O_WRONLY | O_NOCTTY)
        guard fd >= 0 else {
            throw CLIEnv.fail("Could not open \(ttyPath).")
        }
        defer { close(fd) }
        guard let windowSize = PtyProcess.currentWindowSize(masterFD: fd),
              let geometry = InlineImage.CellGeometry(windowSize: windowSize)
        else {
            throw CLIEnv.fail("Pane did not report pixel geometry.")
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let imageSize = InlineImage.sourcePixelSize(source)
        else {
            throw CLIEnv.fail("Could not decode image at \(path).")
        }
        let pad = max(0, pad)
        guard let fit = InlineImage.fit(
            imageWidth: imageSize.width, imageHeight: imageSize.height,
            geometry: geometry, requestedWidth: width, reservedBelow: pad)
        else {
            throw CLIEnv.fail("Pane has \(geometry.rows) rows, too few for an image row plus \(pad) padding rows; pass a smaller --pad.")
        }
        guard let png = PNGThumbnail.encode(source: source, maxPixelSize: max(fit.pixelWidth, fit.pixelHeight)) else {
            throw CLIEnv.fail("Could not decode image at \(path).")
        }
        let bytes = InlineImage.transferBytes(png: png, fit: fit, pad: pad)
        do {
            try bytes.withUnsafeBytes { buffer in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                try SocketIO.writeAll(fd: fd, bytes: base, count: buffer.count)
            }
        } catch {
            throw CLIEnv.fail("Could not write to \(ttyPath).")
        }
        print("Drew \(url.lastPathComponent) at \(fit.cols)x\(fit.rows) cells.")
    }
}

/// Pure helpers behind `graftty image`, separated from the tty / ImageIO
/// shell so the geometry, fit, and byte-sequence rules are unit-testable.
enum InlineImage {
    // MARK: Capability (IMAGE-1.4)

    /// Graftty panes export `TERM=xterm-ghostty` / `TERM_PROGRAM=ghostty`
    /// (see `ZmxSpawnConfiguration.applyTerminalCapabilities`); any other
    /// terminal would print the APC payload as text.
    static func isGhosttyTerminal(environment: [String: String]) -> Bool {
        (environment["TERM"] ?? "").lowercased().contains("ghostty")
            || environment["TERM_PROGRAM"]?.lowercased() == "ghostty"
    }

    // MARK: Terminal discovery (IMAGE-1.1)

    typealias ProcessLookup = (pid_t) -> ProcessAncestryReader.Entry?

    /// Locate the pane's tty. Prefers stdout when it is a terminal;
    /// otherwise walks up from the parent process until an ancestor owns
    /// a controlling terminal.
    static func findTerminal() -> String? {
        if isatty(STDOUT_FILENO) != 0, let name = ttyname(STDOUT_FILENO) {
            return String(cString: name)
        }
        return findTerminal(startingAt: getppid(), lookup: ProcessAncestryReader.entry(forPID:))
    }

    /// Walk `lookup` from `pid` through its ancestors, returning the first
    /// controlling tty. Stops at pid 1 / pid 0, on an unknown pid, or when
    /// the chain cycles.
    static func findTerminal(startingAt pid: pid_t, lookup: ProcessLookup) -> String? {
        var current = pid
        var visited = Set<pid_t>()
        while current > 1, visited.insert(current).inserted {
            guard let entry = lookup(current) else { return nil }
            if let tty = entry.ttyPath { return tty }
            current = entry.parentPID
        }
        return nil
    }

    // MARK: Geometry (IMAGE-1.1)

    struct CellGeometry {
        var cols: Int
        var rows: Int
        var cellWidth: Int
        var cellHeight: Int

        init(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
            self.cols = cols
            self.rows = rows
            self.cellWidth = cellWidth
            self.cellHeight = cellHeight
        }

        /// Derive the cell pixel size from a winsize report. Nil when any
        /// dimension is zero: the terminal (or an intermediate pty layer)
        /// did not propagate pixel geometry, so no fit is possible.
        init?(windowSize: PtyProcess.WindowSize) {
            let cols = Int(windowSize.cols)
            let rows = Int(windowSize.rows)
            guard cols > 0, rows > 0 else { return nil }
            let cellWidth = Int(windowSize.xpixel) / cols
            let cellHeight = Int(windowSize.ypixel) / rows
            guard cellWidth > 0, cellHeight > 0 else { return nil }
            self.init(cols: cols, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight)
        }
    }

    // MARK: Fit (IMAGE-1.2)

    struct Fit {
        var cols: Int
        var rows: Int
        var pixelWidth: Int
        var pixelHeight: Int
        /// True when the row budget, not the column budget, bounds the
        /// image. Kitty stretches an image placed with both `c` and `r` to
        /// fill that cell box, so the placement pins only the binding axis
        /// and the terminal derives the other from the PNG's aspect ratio.
        var heightBound: Bool

        /// Kitty placement key sizing the image (see `heightBound`).
        var placement: String { heightBound ? "r=\(rows)" : "c=\(cols)" }
    }

    /// Scale the image to fit `paneCols - 1` columns (or `requestedWidth`,
    /// when narrower) and `paneRows - 1 - reservedBelow` rows, preserving
    /// aspect ratio, and derive the cells it occupies. The image plus the
    /// `reservedBelow` padding must fit on screen, or the cursor-up clamps
    /// at the top row and the TUI's repaint lands on the picture, so a pane
    /// without room for one image row plus the padding has no fit.
    static func fit(
        imageWidth: Int, imageHeight: Int, geometry: CellGeometry,
        requestedWidth: Int?, reservedBelow: Int
    ) -> Fit? {
        let maxRows = geometry.rows - 1 - reservedBelow
        guard maxRows >= 1 else { return nil }
        let imageWidth = max(1, imageWidth)
        let imageHeight = max(1, imageHeight)
        var maxCols = geometry.cols - 1
        if let requestedWidth { maxCols = min(maxCols, requestedWidth) }
        // The natural width rounded up to whole cells, within the budget.
        let boxWidth = max(1, min(maxCols, ceilDiv(imageWidth, geometry.cellWidth))) * geometry.cellWidth
        let boxHeight = maxRows * geometry.cellHeight
        let heightBound = imageHeight * boxWidth > boxHeight * imageWidth
        let pixelWidth = heightBound ? max(1, imageWidth * boxHeight / imageHeight) : boxWidth
        let pixelHeight = heightBound ? boxHeight : max(1, imageHeight * boxWidth / imageWidth)
        return Fit(
            cols: ceilDiv(pixelWidth, geometry.cellWidth),
            rows: ceilDiv(pixelHeight, geometry.cellHeight),
            pixelWidth: pixelWidth, pixelHeight: pixelHeight, heightBound: heightBound)
    }

    private static func ceilDiv(_ numerator: Int, _ denominator: Int) -> Int {
        (numerator + denominator - 1) / denominator
    }

    // MARK: Decode (IMAGE-1.5)

    /// Pixel size of the first frame / page, as it will be oriented after
    /// `PNGThumbnail` applies the EXIF rotation.
    static func sourcePixelSize(_ source: CGImageSource) -> (width: Int, height: Int)? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        if let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
           width > 0, height > 0 {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            // Orientations 5–8 rotate by 90°, swapping the rendered axes.
            return orientation >= 5 ? (height, width) : (width, height)
        }
        // Vector sources such as PDF report no pixel size; render the page
        // at its native size to measure it.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return nil }
        return (image.width, image.height)
    }

    // MARK: Byte sequence (IMAGE-1.3)

    /// Kitty graphics protocol maximum payload per APC chunk.
    static let chunkSize = 4096

    /// Build the exact byte stream written to the tty:
    ///
    /// 1. `rows + pad` newlines scroll the pane so that many blank rows
    ///    exist below the cursor's eventual position, then `\r` + cursor-up
    ///    returns to the top of the reserved block.
    /// 2. A chunked Kitty graphics transfer (`a=T` direct PNG, `q=2` so
    ///    the terminal never replies into the TUI's stdin, `C=1` so the
    ///    cursor stays put, and `Fit.placement` sizing one axis) places
    ///    the image over the top `rows` rows.
    /// 3. Cursor-down by `rows + pad` lands back on the bottom row, where
    ///    the TUI repaints its live region over the padding only.
    static func transferBytes(png: Data, fit: Fit, pad: Int) -> Data {
        let esc = "\u{1b}"
        let reserved = fit.rows + pad
        let encoded = png.base64EncodedData()
        var out = Data(capacity: encoded.count + encoded.count / chunkSize * 48 + 128)
        out.append(contentsOf: (String(repeating: "\n", count: reserved) + "\r" + esc + "[\(reserved)A").utf8)
        var offset = 0
        repeat {
            let end = min(offset + chunkSize, encoded.count)
            let more = end < encoded.count ? 1 : 0
            let control = offset == 0
                ? "a=T,f=100,t=d,q=2,C=1,\(fit.placement),m=\(more)"
                : "m=\(more)"
            out.append(contentsOf: (esc + "_G" + control + ";").utf8)
            out.append(encoded[offset..<end])
            out.append(contentsOf: (esc + "\\").utf8)
            offset = end
        } while offset < encoded.count
        out.append(contentsOf: (esc + "[\(reserved)B").utf8)
        return out
    }
}
