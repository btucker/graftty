import AppKit
import SwiftUI

/// `NSTitlebarAccessoryViewController` that hosts `UpdateBadge` and installs
/// itself on a window at `layoutAttribute = .leading`, which positions the
/// accessory immediately right of the traffic lights. When the badge's
/// SwiftUI view collapses (no update available), the accessory reports
/// zero intrinsic size and stays invisible — there is no need to remove
/// the accessory dynamically.
@MainActor
public final class UpdaterTitlebarAccessory: NSTitlebarAccessoryViewController {

    private let controller: UpdaterController

    public init(controller: UpdaterController) {
        self.controller = controller
        super.init(nibName: nil, bundle: nil)
        self.layoutAttribute = .leading
        self.view = NSHostingView(rootView: UpdateBadge(controller: controller))
        self.view.translatesAutoresizingMaskIntoConstraints = false
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    /// Attach to the given window idempotently — a second call with the
    /// same window is a no-op so re-entry from SwiftUI's `viewDidMoveToWindow`
    /// doesn't stack duplicate accessories.
    public func install(on window: NSWindow) {
        let alreadyInstalled = window.titlebarAccessoryViewControllers.contains { $0 === self }
        guard !alreadyInstalled else { return }
        window.addTitlebarAccessoryViewController(self)
    }
}
