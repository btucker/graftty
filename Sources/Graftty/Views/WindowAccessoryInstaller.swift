import SwiftUI
import AppKit
import GrafttyKit

/// Installs the update-badge titlebar accessory on the host `NSWindow`
/// once the view is attached. Mirrors the `NSViewRepresentable` +
/// `viewDidMoveToWindow` pattern used by `WindowBackgroundTint`.
///
/// The accessory is cached on the installer view so a window
/// close→reopen (which fires `viewDidMoveToWindow` again with a new
/// window) reuses the same accessory instead of stacking duplicates.
struct WindowAccessoryInstaller: NSViewRepresentable {
    let updaterController: UpdaterController

    func makeNSView(context: Context) -> NSView {
        let view = InstallerView()
        view.updaterController = updaterController
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InstallerView)?.updaterController = updaterController
    }

    private final class InstallerView: NSView {
        var updaterController: UpdaterController?
        private var accessory: UpdaterTitlebarAccessory?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let controller = updaterController else { return }
            let accessory = self.accessory ?? UpdaterTitlebarAccessory(controller: controller)
            self.accessory = accessory
            accessory.install(on: window)
        }
    }
}

extension View {
    /// Install the update-badge accessory in the host window's titlebar.
    func installUpdateBadgeAccessory(controller: UpdaterController) -> some View {
        background(WindowAccessoryInstaller(updaterController: controller))
    }
}
