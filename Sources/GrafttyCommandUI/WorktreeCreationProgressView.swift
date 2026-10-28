import SwiftUI
import GrafttyProtocol

/// Compact status on a worktree row. Selecting the row opens its diagnostics
/// in the terminal content area, so the status needs no separate click target.
public struct WorktreeCreationProgressView: View {
    public let progress: WorktreeCreationProgress

    public init(progress: WorktreeCreationProgress) { self.progress = progress }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: progress.creationSymbolName).accessibilityHidden(true)
                Text(progress.label)
                Text(progress.duration(at: context.date)).monospacedDigit()
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}

/// Creation occupies the same main content area as the terminal until startup
/// completes. It has no popover or modal event loop, on either platform.
public struct WorktreeCreationDetailView: View {
    public let progress: WorktreeCreationProgress
    private let foreground: Color
    private let background: Color
    private let onOpenTerminal: (() -> Void)?

    public init(progress: WorktreeCreationProgress, foreground: Color = .primary,
                background: Color = .clear, onOpenTerminal: (() -> Void)? = nil) {
        self.progress = progress
        self.foreground = foreground
        self.background = background
        self.onOpenTerminal = onOpenTerminal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: progress.creationSymbolName).accessibilityHidden(true)
                Text(progress.label)
            }
            .font(.title3.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text("Elapsed: \(progress.duration(at: context.date))")
                    .font(.callout).monospacedDigit().foregroundStyle(foreground.opacity(0.65))
            }
            if progress.isPending {
                Text("A pane or agent will start after Git and its hooks finish.")
                    .font(.callout)
            }
            if let error = progress.error { Text(error).font(.callout).textSelection(.enabled) }
            if !progress.isPending, let onOpenTerminal {
                Button("Open terminal", action: onOpenTerminal)
            }
            if progress.outputTruncated {
                Text("Earlier output omitted. Showing recent output.")
                    .font(.caption).foregroundStyle(foreground.opacity(0.65))
            }
            ScrollView([.vertical, .horizontal]) {
                Text(progress.output.isEmpty ? "No Git or hook output yet." : progress.output)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(foreground.opacity(0.04))
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(foreground)
        .background(background)
    }
}

private extension WorktreeCreationProgress {
    var creationSymbolName: String {
        isPending ? "gearshape.2" : phase == .ready ? "checkmark.circle" : "exclamationmark.triangle"
    }

    func duration(at date: Date) -> String {
        let seconds = Int(elapsed(at: date))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
