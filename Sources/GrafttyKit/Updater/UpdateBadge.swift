import SwiftUI

/// Pill-shaped titlebar button visible only when a pending update exists.
/// Clicking routes through `UpdaterController.showPendingUpdate()`, which
/// triggers a user-initiated check — Sparkle's standard driver then shows
/// its install dialog and owns the UI from there.
public struct UpdateBadge: View {
    @ObservedObject public var controller: UpdaterController

    public init(controller: UpdaterController) {
        self.controller = controller
    }

    public var body: some View {
        if let version = controller.availableVersion {
            Button {
                controller.showPendingUpdate()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text("v\(version)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.accentColor.opacity(0.85))
                )
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Update to Graftty v\(version) available")
        }
    }
}
