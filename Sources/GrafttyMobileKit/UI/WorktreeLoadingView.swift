#if canImport(UIKit)
import GrafttyProtocol
import GrafttyCommandUI
import SwiftUI

struct WorktreeLoadingView: View {
    static let detailRevealDelay: Duration = .milliseconds(750)

    let hostLabel: String
    let stage: RemoteWorktreeLoadStage

    @State private var startedAt = Date()
    @State private var detailsVisible = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Loading worktrees…")
                .foregroundStyle(.secondary)

            if detailsVisible {
                VStack(spacing: 3) {
                    Text(Self.detail(for: stage, hostLabel: hostLabel))
                    TimelineView(.periodic(from: startedAt, by: 1)) {
                        context in
                        Text(Self.elapsedText(
                            startedAt: startedAt,
                            now: context.date
                        ))
                        .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .transition(.opacity)
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .task {
            do {
                try await Task.sleep(for: Self.detailRevealDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                detailsVisible = true
            }
        }
    }

    static func detail(
        for stage: RemoteWorktreeLoadStage,
        hostLabel: String
    ) -> String {
        switch stage {
        case .connecting:
            return "Connecting securely to \(hostLabel)…"
        case .openingChannel:
            return "Opening secure worktree channel…"
        case .waitingForSnapshot:
            return "Waiting for worktree list…"
        }
    }

    static func elapsedText(startedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
        return "Elapsed \(seconds)s"
    }
}
#endif
