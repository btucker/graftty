#if canImport(UIKit)
import SwiftUI

public struct SessionSwitcherView: View {
    @Bindable var controller: HostController
    @Binding var activePaneID: UUID?

    public init(controller: HostController, activePaneID: Binding<UUID?>) {
        self.controller = controller
        self._activePaneID = activePaneID
    }

    public var body: some View {
        if controller.panes.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(controller.panes) { pane in
                        Button(pane.sessionName) { activePaneID = pane.id }
                            .buttonStyle(.bordered)
                            .tint(activePaneID == pane.id ? .accentColor : .secondary)
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
    }
}
#endif
