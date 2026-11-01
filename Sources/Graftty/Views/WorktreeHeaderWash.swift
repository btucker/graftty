import GrafttyCommandUI
import GrafttyProtocol
import SwiftUI

extension WorktreeHeaderWash {
    /// Header surfaces draw slices of one band in this coordinate space, so
    /// the breadcrumb and every top-row tab header line up seamlessly.
    static let coordinateSpace = "worktreeHeaderWash"
    /// The tab row below the breadcrumb is part of the band.
    static let tabRowHeight: CGFloat = 36
}

struct WorktreeHeaderWashBand: Equatable {
    let wash: WorktreeHeaderWash
    let size: CGSize
}

private struct WorktreeHeaderWashBandKey: EnvironmentKey {
    static let defaultValue: WorktreeHeaderWashBand? = nil
}

extension EnvironmentValues {
    var worktreeHeaderWashBand: WorktreeHeaderWashBand? {
        get { self[WorktreeHeaderWashBandKey.self] }
        set { self[WorktreeHeaderWashBandKey.self] = newValue }
    }
}

extension View {
    /// Overlays this surface's slice of the header band. Surfaces outside the
    /// band, such as tab headers of lower split panes, draw nothing.
    func worktreeHeaderWash() -> some View {
        overlay { WorktreeHeaderWashSlice() }
    }
}

private struct WorktreeHeaderWashSlice: View {
    @Environment(\.worktreeHeaderWashBand) private var band

    var body: some View {
        if let band {
            GeometryReader { proxy in
                let origin = proxy.frame(in: .named(WorktreeHeaderWash.coordinateSpace)).origin
                if origin.y < band.size.height {
                    WorktreeHeaderWashView(wash: band.wash)
                        .frame(width: band.size.width, height: band.size.height)
                        .offset(x: -origin.x, y: -origin.y)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
