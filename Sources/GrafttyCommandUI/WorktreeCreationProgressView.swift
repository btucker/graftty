import SwiftUI
import GrafttyProtocol

/// Shared creation status and output inspector for Mac and mobile rows.
public struct WorktreeCreationProgressView: View {
    public let progress: WorktreeCreationProgress
    @State private var showsOutput = false

    public init(progress: WorktreeCreationProgress) { self.progress = progress }

    public var body: some View {
        Button { showsOutput = true } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 4) {
                    Image(systemName: progress.isPending ? "text.alignleft" : progress.phase == .ready ? "checkmark.circle" : "exclamationmark.triangle")
                    Text(progress.label)
                    Text(duration(at: context.date)).monospacedDigit()
                }
                .font(.caption)
                .lineLimit(1)
            }
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("\(progress.label). Inspect creation output")
        .popover(isPresented: $showsOutput) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(progress.label).font(.headline)
                    Spacer()
                    Button("Done") { showsOutput = false }
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Elapsed: \(duration(at: context.date))").font(.caption).monospacedDigit()
                }
                if progress.phase == .git {
                    Text("Git and its hooks must finish before a pane or agent can start.")
                        .font(.callout)
                }
                if let error = progress.error { Text(error).font(.callout) }
                if progress.outputTruncated {
                    Text("Earlier output omitted. Showing recent output.").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(progress.output.isEmpty ? "No Git or hook output yet." : progress.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 120, maxHeight: 300)
                .background(.quaternary)
            }
            .padding(16)
            .foregroundStyle(Color.primary)
            .background(.background)
            .frame(idealWidth: 420, maxWidth: 520)
            .presentationCompactAdaptation(.sheet)
        }
    }

    private func duration(at date: Date) -> String {
        let seconds = Int(progress.elapsed(at: date))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
