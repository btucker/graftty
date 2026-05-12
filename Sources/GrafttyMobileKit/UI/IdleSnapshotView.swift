#if canImport(UIKit)
import SwiftUI
import UIKit

/// Replaces a live `TerminalPaneView` while its `SessionClient` is in
/// `.idle` so libghostty's display link can stop. Renders the captured
/// last frame if available, falls back to a stylized dim placeholder
/// otherwise. A full-bleed tap target invokes `onWake`.
/// See IOS-10.4 for the snapshot state on `SessionClient.idleSnapshot`.
struct IdleSnapshotView: View {
    let snapshot: UIImage?
    let onWake: () -> Void

    var body: some View {
        ZStack {
            if let snapshot {
                Image(uiImage: snapshot)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .overlay(Color.black.opacity(0.05))
            } else {
                Color.black
            }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Label("Tap to wake", systemImage: "hand.tap")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onWake() }
    }
}
#endif
