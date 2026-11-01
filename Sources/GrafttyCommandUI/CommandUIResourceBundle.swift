import Foundation

/// Resolve shipped resources before SwiftPM's build-machine fallback.
enum CommandUIResourceBundle {
    static let bundleName = "Graftty_GrafttyCommandUI.bundle"
    static let bundle: Bundle? = resolve()

    static func resolve(
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL,
        moduleFallback: () -> Bundle = { .module }
    ) -> Bundle? {
        for base in [mainResourceURL, mainBundleURL].compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(bundleName)) { return bundle }
        }
        // A missing asset must not crash the app while opening an agent menu.
        // The generated accessor traps if neither of its development paths exists.
        guard mainBundleURL.pathExtension != "app" else { return nil }
        return moduleFallback()
    }
}
