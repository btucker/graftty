import SwiftUI

public extension View {
    /// Make gaps clickable while allowing individual controls to handle their own clicks.
    func terminalDrawerHitArea(onToggle: @escaping () -> Void) -> some View {
        contentShape(Rectangle()).onTapGesture(perform: onToggle)
    }
}
