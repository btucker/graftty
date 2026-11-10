//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private static let slowSurfaceWriteThreshold: TimeInterval = 0.5

    private let resizeLock = NSLock()
    let surfaceAccess: InMemoryTerminalSurfaceAccess
    let snapshotOperations: InMemoryTerminalSnapshotOperations
    private var lastResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    /// Skip resize dispatches whose grid is unchanged and only the pixel
    /// metrics moved.
    ///
    /// Off by default: the resize closure is a lossless contract, and a host
    /// that reads `widthPixels`/`heightPixels` would otherwise stop seeing
    /// sub-cell changes — permanently, if the grid never changes again.
    ///
    /// Worth enabling for a host that only consumes columns and rows and
    /// repaints on every dispatch. A live divider drag produces mostly
    /// pixel-only updates (measured at ~78% of metric updates across one
    /// session's drags), and each one asks the terminal app for a full
    /// repaint that re-wraps its content.
    public let suppressesPixelOnlyResizes: Bool

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
        suppressesPixelOnlyResizes: Bool = false,
    ) {
        writeHandler = write
        resizeHandler = resize
        self.suppressesPixelOnlyResizes = suppressesPixelOnlyResizes
        snapshotOperations = .live
        surfaceAccess = InMemoryTerminalSurfaceAccess(
            write: Self.writeToSurface,
            processExit: Self.reportProcessExit,
            tick: Self.tickApp,
        )
    }

    /// Test seam: the surface handed to `setSurface` is a stand-in, so every
    /// C call on it is injected, and the tick defaults to a no-op.
    init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void,
        suppressesPixelOnlyResizes: Bool = false,
        surfaceWrite: @escaping InMemoryTerminalSurfaceAccess.Write,
        processExit: @escaping InMemoryTerminalSurfaceAccess.ProcessExit =
            InMemoryTerminalSession.reportProcessExit,
        tick: @escaping InMemoryTerminalSurfaceAccess.Tick = { _ in },
        snapshotOperations: InMemoryTerminalSnapshotOperations = .live,
    ) {
        writeHandler = write
        resizeHandler = resize
        self.suppressesPixelOnlyResizes = suppressesPixelOnlyResizes
        self.snapshotOperations = snapshotOperations
        surfaceAccess = InMemoryTerminalSurfaceAccess(
            write: surfaceWrite,
            processExit: processExit,
            tick: tick,
        )
    }

    // MARK: - Surface Lifecycle

    func setSurface(
        _ surface: ghostty_surface_t?,
        processMailbox: (() -> Void)? = nil,
        whileWaiting progress: () -> Void = {}
    ) {
        surfaceAccess.setSurface(surface, processMailbox: processMailbox, whileWaiting: progress)
        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")",
        )
    }

    func clearSurface(
        ifMatches expectedSurface: ghostty_surface_t?,
        whileWaiting progress: () -> Void = {}
    ) {
        guard surfaceAccess.clearSurface(ifMatches: expectedSurface, whileWaiting: progress) else {
            TerminalDebugLog.log(
                .lifecycle,
                "in-memory session clear skipped expected=\(expectedSurface == nil ? "nil" : "set") current=\(surfaceAccess.currentSurface == nil ? "nil" : "set")",
            )
            return
        }

        TerminalDebugLog.log(.lifecycle, "in-memory session surface=nil matched")
    }

    var currentSurface: ghostty_surface_t? {
        surfaceAccess.currentSurface
    }

    // MARK: - Viewport Read

    /// Returns the viewport's logical text, joining soft wraps and preserving
    /// hard line breaks, or `nil` if no surface is attached. The native linear
    /// selection reads only the visible viewport, excluding scrollback.
    /// Use ``readViewportRowsText()`` when indexing by physical screen row.
    /// The surface stays leased until the native read and buffer release finish.
    public func readViewportText() -> String? {
        surfaceAccess.withCurrentSurface { surface in
            Self.readViewportFlow(on: surface, startingAt: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ))?.text
        } ?? nil
    }

    /// Returns one line per physical viewport row, joined with `\n`, or `nil`
    /// if no surface is attached. Soft-wrapped continuations remain separate.
    ///
    /// Each row is its own read, `(VIEWPORT, EXACT (0, y))` to
    /// `(VIEWPORT, EXACT (columns - 1, y))`: a single read over the whole
    /// viewport unwraps a soft-wrapped row into its neighbour's line, and
    /// callers index these lines by viewport row. This reads exactly the
    /// visible rows and ignores scrollback. Empty viewports
    /// return an empty string.
    ///
    /// Thread-safe: keeps the surface alive for the duration of the read,
    /// preventing access against a surface mid-replacement.
    public func readViewportRowsText() -> String? {
        surfaceAccess.withCurrentSurface { surface -> String? in
            let size = ghostty_surface_size(surface)
            guard size.columns > 0 else { return "" }
            var lines: [String] = []
            for row in 0 ..< UInt32(size.rows) {
                let selection = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_EXACT,
                        x: 0,
                        y: row,
                    ),
                    bottom_right: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_EXACT,
                        x: UInt32(size.columns) - 1,
                        y: row,
                    ),
                    rectangle: false,
                )

                guard let text = Self.readText(on: surface, selection: selection) else { return nil }
                lines.append(text.text)
            }
            return lines.joined(separator: "\n")
        } ?? nil
    }

    /// Native cell coordinates locate a suffix of the same logical snapshot,
    /// so wraps and wide characters need no guessed UTF-16 column mapping.
    /// A suffix that no longer matches the supplied snapshot is rejected
    /// rather than paired with an unrelated range.
    func nativeViewportColumns() -> UInt32? {
        surfaceAccess.withCurrentSurface { Self.nativeViewportColumns(on: $0) } ?? nil
    }

    func viewportTextAnchorRange(
        word: String,
        cellOffset: UInt32,
        in text: String,
        expectedColumns: UInt32? = nil
    ) -> NSRange? {
        guard !word.isEmpty else { return nil }
        return surfaceAccess.withCurrentSurface { surface -> NSRange? in
            guard let columns = Self.nativeViewportColumns(on: surface),
                  expectedColumns == nil || expectedColumns == columns
            else { return nil }
            let start = ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_EXACT,
                x: cellOffset % columns,
                y: cellOffset / columns
            )
            guard let suffix = Self.readViewportFlow(on: surface, startingAt: start),
                  suffix.cellOffset == cellOffset,
                  suffix.text.utf8.starts(with: word.utf8),
                  text.utf8.suffix(suffix.text.utf8.count).elementsEqual(suffix.text.utf8)
            else { return nil }
            return NSRange(location: text.utf16.count - suffix.text.utf16.count, length: word.utf16.count)
        } ?? nil
    }

    private struct ViewportRead {
        let text: String
        let cellOffset: UInt32
        let cellLength: UInt32
    }

    private static func nativeViewportColumns(on surface: ghostty_surface_t) -> UInt32? {
        // Native offsets use parser columns, which can lag the UI grid during
        // asynchronous resize. The first cell of row one reveals that width.
        let point = ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: 1)
        guard let row = readText(on: surface, selection: ghostty_selection_s(
            top_left: point, bottom_right: point, rectangle: false
        )) else { return nil }
        if row.cellOffset > 0 { return row.cellOffset }
        // Native coordinates clamp row one to row zero on a single-row grid.
        // Its full viewport span then directly supplies columns minus one.
        guard let full = readViewportFlow(on: surface, startingAt: ghostty_point_s(
            tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0
        )), full.cellOffset == 0, full.cellLength < UInt32.max else { return nil }
        return full.cellLength + 1
    }

    private static func readViewportFlow(on surface: ghostty_surface_t, startingAt start: ghostty_point_s) -> ViewportRead? {
        readText(on: surface, selection: ghostty_selection_s(
            top_left: start,
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        ))
    }

    private static func readText(on surface: ghostty_surface_t, selection: ghostty_selection_s) -> ViewportRead? {
        var out = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &out) else { return nil }
        defer { ghostty_surface_free_text(surface, &out) }
        let text: String
        if let textPtr = out.text, out.text_len > 0 {
            let bytes = UnsafeBufferPointer(start: textPtr, count: Int(out.text_len))
                .map { UInt8(bitPattern: $0) }
            text = String(decoding: bytes, as: UTF8.self)
        } else {
            text = ""
        }
        return ViewportRead(text: text, cellOffset: out.offset_start, cellLength: out.offset_len)
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels,
        ))
    }

    // MARK: - Receiving Data

    /// Enqueue data for the terminal from the host backend.
    ///
    /// Writes are processed in order on a per-session serial queue so parsing
    /// cannot block the caller or the main thread. Bytes that arrive before a
    /// surface attaches are buffered (oldest dropped past a 1 MiB cap) and
    /// flushed on attach — hosts do not need to hold their connection until
    /// the first viewport report. Bytes still queued when a surface is torn
    /// down go to the next one too.
    public func receive(_ data: Data) {
        surfaceAccess.enqueueWrite(data)
        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))",
        )
    }

    /// Bytes passed to ``receive(_:)`` that the terminal has not parsed yet.
    ///
    /// `receive(_:)` never blocks, so a transport faster than the parser
    /// queues output here without limit while a surface is attached. A host
    /// that can pause its source reads this, or registers
    /// ``setOutputBacklogHandler(highWater:lowWater:_:)``, to apply
    /// backpressure.
    public var pendingOutputByteCount: Int {
        surfaceAccess.pendingByteCount
    }

    /// Calls `handler(true)` once unparsed output reaches `highWater` bytes
    /// and `handler(false)` once it falls back to `lowWater` or below — the
    /// moments for a host to pause and resume its transport. The handler runs
    /// on whichever thread crossed the mark (a `receive(_:)` caller or the
    /// session's output queue), outside the session's lock. A new handler
    /// replaces the previous one and starts unbacklogged, so it hears `true`
    /// straight away when the backlog is already past `highWater`; `nil`
    /// removes it.
    public func setOutputBacklogHandler(
        highWater: Int,
        lowWater: Int,
        _ handler: (@Sendable (_ isBacklogged: Bool) -> Void)?,
    ) {
        precondition(lowWater < highWater, "lowWater must be below highWater")
        surfaceAccess.setBacklogObserver(handler.map {
            .init(highWater: highWater, lowWater: lowWater, handler: $0)
        })
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))",
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Enqueue a host-managed process exit after all previously received data.
    /// Like that data, an exit that arrives before a surface attaches waits
    /// for the next one, in the same order relative to the buffered bytes.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        surfaceAccess.enqueueProcessExit(
            exitCode: exitCode,
            runtimeMilliseconds: runtimeMilliseconds,
        )
        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)",
        )
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))",
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)",
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx,
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        resizeLock.lock()
        let mergedResize = mergedResize(resize)
        guard mergedResize != lastResize else {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)",
            )
            return
        }
        // Opt-in (`suppressesPixelOnlyResizes`): only a change in grid size
        // changes what a terminal app has to draw, so a host that repaints on
        // every dispatch can skip the sub-cell ones. The latest pixel metrics
        // are still recorded, so a later grid change carries them — but a host
        // that consumes pixels must leave this off, because without a further
        // grid change that update is never delivered.
        let gridChanged = lastResize.map {
            $0.columns != mergedResize.columns || $0.rows != mergedResize.rows
        } ?? true
        lastResize = mergedResize
        if suppressesPixelOnlyResizes, !gridChanged {
            resizeLock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize sub-cell skipped cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels)",
            )

            return
        }

        resizeLock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)",
        )
        resizeHandler(mergedResize)
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels,
        )
    }

    /// Blocks until every `receive(_:)` call made so far has been fully parsed by the
    /// terminal engine's internal serial queue, including any resulting writeback (e.g.
    /// DECRPM/DA/OSC query responses the engine generates while parsing).
    ///
    /// `receive(_:)` only enqueues — it returns before parsing happens. A host that feeds
    /// buffered/replayed history and then flips some "replay done" flag on its own signal
    /// (rather than on this call returning) can observe writeback for that history arrive
    /// late, after the flag already says replay is over.
    ///
    /// Output received while no surface is attached is parsed only when the next surface
    /// attaches, so this call cannot wait for it: it returns `false` when such output is
    /// still waiting, and the writeback for it arrives after that attach. A host that
    /// replays history before the view has attached its surface should treat `false` as
    /// "replay not done yet".
    ///
    /// Safe on the main thread: parsing fills ghostty's app mailbox, which only the main
    /// thread drains, so a main-thread caller ticks the app while it waits.
    @discardableResult
    public func waitForPendingOutput() -> Bool {
        surfaceAccess.waitForPendingOutput()
    }

    private static func writeToSurface(_ surface: ghostty_surface_t, _ data: Data) {
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let duration = ProcessInfo.processInfo.systemUptime - start
            if duration >= slowSurfaceWriteThreshold {
                TerminalDebugLog.log(
                    .output,
                    "surface write slow bytes=\(data.count) duration=\(String(format: "%.3f", duration))s",
                )
            }
        }

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    private static func reportProcessExit(
        _ surface: ghostty_surface_t,
        _ exitCode: UInt32,
        _ runtimeMilliseconds: UInt64,
    ) {
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    private static func tickApp(_ surface: ghostty_surface_t) {
        ghostty_app_tick(ghostty_surface_app(surface))
    }
}
