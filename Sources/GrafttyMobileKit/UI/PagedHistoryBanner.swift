#if canImport(UIKit)
import GrafttyRemoteClient
import SwiftUI

struct PagedHistoryBanner: View {
    let paging: PagedTerminalCoordinator

    var body: some View {
        switch paging.status {
        case .installing:
            message("Restoring terminal") { ProgressView() }
        case .loading:
            message("Loading older history") { ProgressView() }
        case .requiresRecovery:
            message("Older history needs a fresh snapshot") {
                Button("Reload from live screen") { Task { await paging.recover() } }
            }
        case .unavailable:
            message("Couldn't load older history") {
                Button("Retry") { Task { await paging.retry() } }
            }
        case .limit:
            message("History memory limit reached") { EmptyView() }
        case .inactive, .available, .complete:
            EmptyView()
        }
    }

    private func message<Accessory: View>(_ text: String, @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 10) {
            Text(text)
            accessory()
        }
        .font(.callout)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}
#endif
