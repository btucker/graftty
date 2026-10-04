import CoreGraphics
import Foundation
import GrafttyKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import GrafttyCLI

struct ImageCLITests {
    private typealias Entry = ProcessAncestryReader.Entry

    @Test("@spec IMAGE-1.1: When the user runs graftty image, the CLI shall locate the pane terminal through the caller's process ancestry and read its cell pixel geometry, and shall exit nonzero with a reason when no terminal or pixel geometry is available.")
    func locatesTerminalThroughAncestryAndReadsGeometry() throws {
        // Fake tree: 500 (graftty, no tty) -> 400 (agent, no tty) -> 300 (shell, tty) -> 1.
        let tree: [pid_t: Entry] = [
            500: Entry(parentPID: 400, ttyPath: nil),
            400: Entry(parentPID: 300, ttyPath: nil),
            300: Entry(parentPID: 1, ttyPath: "/dev/ttys007"),
        ]
        #expect(InlineImage.findTerminal(startingAt: 500, lookup: { tree[$0] }) == "/dev/ttys007")
        // No ancestor owns a tty: the walk stops at pid 1 and reports nothing.
        let headless: [pid_t: Entry] = [500: Entry(parentPID: 400, ttyPath: nil), 400: Entry(parentPID: 1, ttyPath: nil)]
        #expect(InlineImage.findTerminal(startingAt: 500, lookup: { headless[$0] }) == nil)
        // A cycle or an unknown pid terminates the walk instead of looping.
        let cyclic: [pid_t: Entry] = [500: Entry(parentPID: 400, ttyPath: nil), 400: Entry(parentPID: 500, ttyPath: nil)]
        #expect(InlineImage.findTerminal(startingAt: 500, lookup: { cyclic[$0] }) == nil)
        #expect(InlineImage.findTerminal(startingAt: 500, lookup: { _ in nil }) == nil)

        let geometry = try #require(InlineImage.CellGeometry(
            windowSize: PtyProcess.WindowSize(cols: 80, rows: 24, xpixel: 1600, ypixel: 960)))
        #expect(geometry.cols == 80)
        #expect(geometry.rows == 24)
        #expect(geometry.cellWidth == 20)
        #expect(geometry.cellHeight == 40)
        // Any zero dimension means the pty layer dropped pixel geometry.
        for windowSize in [
            PtyProcess.WindowSize(cols: 80, rows: 24, xpixel: 0, ypixel: 960),
            PtyProcess.WindowSize(cols: 80, rows: 24, xpixel: 1600, ypixel: 0),
            PtyProcess.WindowSize(cols: 0, rows: 24, xpixel: 1600, ypixel: 960),
            PtyProcess.WindowSize(cols: 80, rows: 0, xpixel: 1600, ypixel: 960),
        ] {
            #expect(InlineImage.CellGeometry(windowSize: windowSize) == nil)
        }
    }

    @Test("@spec IMAGE-1.2: When graftty image fits an image, the CLI shall scale it to at most the pane width or the requested width while preserving aspect ratio, derive the occupied cell rows from the pane's cell pixel size, and keep the image rows plus the padding within the pane height so the padding block stays on screen, exiting nonzero when the pane has no room for one image row plus the padding.")
    func fitsWithinPaneAndRequestedWidth() throws {
        let cell = InlineImage.CellGeometry(cols: 80, rows: 24, cellWidth: 10, cellHeight: 20)
        func fit(_ width: Int, _ height: Int, requestedWidth: Int? = nil, reservedBelow: Int = 0) throws -> InlineImage.Fit {
            try #require(InlineImage.fit(
                imageWidth: width, imageHeight: height, geometry: cell,
                requestedWidth: requestedWidth, reservedBelow: reservedBelow))
        }
        // Small image: occupies ceil(width / cellWidth) columns, rows from aspect ratio.
        let small = try fit(95, 50)
        #expect(small.cols == 10)
        #expect(small.pixelWidth == 100)
        #expect(small.pixelHeight == 52)
        #expect(small.rows == 3)
        #expect(small.placement == "c=10")
        // Wide image is capped at paneCols - 1 and keeps its aspect ratio.
        let wide = try fit(2000, 500)
        #expect(wide.cols == 79)
        #expect(wide.pixelWidth == 790)
        #expect(wide.pixelHeight == 197)
        #expect(wide.rows == 10)
        // --width narrows further.
        let narrowed = try fit(2000, 500, requestedWidth: 40)
        #expect(narrowed.cols == 40)
        #expect(narrowed.pixelWidth == 400)
        #expect(narrowed.rows == 5)
        // Tall image fills paneRows - 1 rows; the placement pins rows, not
        // columns, so the terminal keeps its aspect ratio instead of
        // stretching it to a whole-column box.
        let tall = try fit(400, 4000)
        #expect(tall.cols == 5)
        #expect(tall.pixelWidth == 46)
        #expect(tall.pixelHeight == 460)
        #expect(tall.rows == 23)
        #expect(tall.placement == "r=23")
        // Padding below the image counts against the pane height too, or
        // the TUI's repaint lands on the image's bottom rows in a short pane.
        let padded = try fit(400, 4000, reservedBelow: 12)
        #expect(padded.cols == 3)
        #expect(padded.rows == 11)
        // A full-page screenshot narrower than one column at the height
        // cap still honors the row budget.
        let screenshot = try fit(1280, 40000, reservedBelow: 12)
        #expect(screenshot.cols == 1)
        #expect(screenshot.rows == 11)
        // A pane without room for one image row plus the padding has no fit.
        let short = InlineImage.CellGeometry(cols: 80, rows: 13, cellWidth: 10, cellHeight: 20)
        for reservedBelow in [12, Int.max] {
            #expect(InlineImage.fit(
                imageWidth: 100, imageHeight: 100, geometry: short,
                requestedWidth: nil, reservedBelow: reservedBelow) == nil)
        }
        // Never collapses to zero cells.
        let tiny = try fit(1, 1, requestedWidth: 0)
        #expect(tiny.cols == 1)
        #expect(tiny.rows == 1)
    }

    @Test("@spec IMAGE-1.3: When graftty image draws, the CLI shall reserve the image rows plus a padding block of blank rows below the image before placing it with a quiet Kitty graphics PNG transfer that leaves the cursor in place, so a TUI that repaints its live region does not overwrite the image.")
    func reservesRowsAndEmitsQuietTransfer() throws {
        let png = Data((0..<10_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let wide = InlineImage.Fit(cols: 20, rows: 1, pixelWidth: 200, pixelHeight: 15, heightBound: false)
        let bytes = InlineImage.transferBytes(png: png, fit: wide, pad: 12)
        let text = try #require(String(data: bytes, encoding: .utf8))
        let esc = "\u{1b}"

        // Reserve rows+pad lines, return to column 0, move back up over them.
        let prefix = String(repeating: "\n", count: 13) + "\r" + esc + "[13A"
        #expect(text.hasPrefix(prefix))
        // Cursor returns to the bottom row afterwards.
        #expect(text.hasSuffix(esc + "[13B"))

        let body = String(text.dropFirst(prefix.count).dropLast((esc + "[13B").count))
        let chunks = body.components(separatedBy: esc + "\\").filter { !$0.isEmpty }
        #expect(chunks.count == png.base64EncodedString().count / 4096 + 1)
        var payloads: [String] = []
        for (index, chunk) in chunks.enumerated() {
            #expect(chunk.hasPrefix(esc + "_G"))
            let parts = chunk.dropFirst((esc + "_G").count).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            #expect(parts.count == 2)
            let control = String(parts[0])
            let payload = String(parts[1])
            #expect(payload.count <= 4096)
            payloads.append(payload)
            let isLast = index == chunks.count - 1
            if index == 0 {
                #expect(control.hasPrefix("a=T,f=100,t=d,q=2,C=1,c=20,m="))
            } else {
                #expect(control.hasPrefix("m="))
            }
            #expect(control.hasSuffix(isLast ? "m=0" : "m=1"))
        }
        #expect(Data(base64Encoded: payloads.joined()) == png)

        // A single-chunk transfer still terminates with m=0, and a
        // height-bound fit sizes the placement by rows alone.
        let tall = InlineImage.Fit(cols: 4, rows: 2, pixelWidth: 35, pixelHeight: 40, heightBound: true)
        let short = try #require(String(data: InlineImage.transferBytes(png: Data([1, 2, 3]), fit: tall, pad: 0), encoding: .utf8))
        #expect(short.contains(esc + "_Ga=T,f=100,t=d,q=2,C=1,r=2,m=0;AQID" + esc + "\\"))
        #expect(short.hasPrefix("\n\n\r" + esc + "[2A"))
    }

    @Test("@spec IMAGE-1.4: If the terminal does not identify as ghostty, then graftty image shall exit nonzero with a message directing the agent to graftty open.")
    func rejectsTerminalsOtherThanGhostty() {
        #expect(InlineImage.isGhosttyTerminal(environment: ["TERM": "xterm-ghostty"]))
        #expect(InlineImage.isGhosttyTerminal(environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "ghostty"]))
        #expect(!InlineImage.isGhosttyTerminal(environment: ["TERM": "xterm-kitty"]))
        #expect(!InlineImage.isGhosttyTerminal(environment: ["TERM": "xterm-256color", "TERM_PROGRAM": "Apple_Terminal"]))
        #expect(!InlineImage.isGhosttyTerminal(environment: [:]))
    }

    @Test("@spec IMAGE-1.5: When graftty image receives any ImageIO-readable image, the CLI shall re-encode it as PNG at the fitted pixel width before transfer.")
    func reencodesAnyImageIOFormatAsPNG() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graftty-image-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSolidJPEG(width: 64, height: 32, to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let size = try #require(InlineImage.sourcePixelSize(source))
        #expect(size.width == 64)
        #expect(size.height == 32)

        let png = try #require(PNGThumbnail.encode(source: source, maxPixelSize: 32))
        let decoded = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)
        let image = try #require(CGImageSourceCreateImageAtIndex(decoded, 0, nil))
        #expect(image.width == 32)
        #expect(image.height == 16)

        // PDFs expose no pixel-size properties; the page is measured instead.
        let pdfURL = url.deletingPathExtension().appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: pdfURL) }
        var box = CGRect(x: 0, y: 0, width: 200, height: 100)
        let pdf = try #require(CGContext(pdfURL as CFURL, mediaBox: &box, nil))
        pdf.beginPDFPage(nil)
        pdf.fill(box)
        pdf.endPDFPage()
        pdf.closePDF()
        let pdfSource = try #require(CGImageSourceCreateWithURL(pdfURL as CFURL, nil))
        let pdfSize = try #require(InlineImage.sourcePixelSize(pdfSource))
        #expect(pdfSize.width == 200)
        #expect(pdfSize.height == 100)

        let missing = url.deletingLastPathComponent().appendingPathComponent("missing-\(UUID().uuidString).png")
        #expect(CGImageSourceCreateWithURL(missing as CFURL, nil).flatMap(InlineImage.sourcePixelSize) == nil)
    }

    private static func writeSolidJPEG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
