#if canImport(UIKit)
    import UIKit

    public extension UITerminalView {
        /// Controls render frequency without pausing native mailbox processing.
        var renderPace: TerminalRenderPace {
            get { core.renderPace }
            set { core.renderPace = newValue }
        }
    }
#endif
