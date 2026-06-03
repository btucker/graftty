import Foundation

/// @spec CONFIG-2.6
/// Resolves GrafttyKit's SwiftPM resource bundle in a way that works inside the
/// distributed `.app`, where SwiftPM's generated `Bundle.module` accessor traps.
///
/// The generated accessor probes only two locations:
///   1. `Bundle.main.bundleURL/Graftty_GrafttyKit.bundle` — the `.app` *root*
///   2. the absolute `.build/.../Graftty_GrafttyKit.bundle` path of the machine
///      that compiled it
/// Neither exists in a shipped app: `scripts/bundle.sh` places the resource
/// bundle under `Contents/Resources/` (Apple's required layout — a foreign item
/// at the `.app` root fails `codesign --strict`/notarization), and the build
/// path belongs to the CI runner. Touching `Bundle.module` in shipped code
/// therefore traps with "could not load resource bundle" — the v0.1.10 launch
/// crash, latent until a startup code path (CONFIG-2.x) first accessed it.
///
/// This locator probes `Contents/Resources/` first (the packaged layout), then
/// the main-bundle root (flat/CLI layout), and only falls back to
/// `Bundle.module` for `swift test`/`swift run`, where the accessor's build-path
/// branch still resolves.
enum GrafttyKitResourceBundle {
    static let bundleName = "Graftty_GrafttyKit.bundle"

    /// The process-wide resolved bundle. Resolved once; safe for shipped code.
    static let bundle: Bundle = resolve()

    /// Pure resolution against explicit inputs so the precedence is unit-testable
    /// without depending on the test host's real bundle layout.
    static func resolve(
        mainResourceURL: URL? = Bundle.main.resourceURL,
        mainBundleURL: URL = Bundle.main.bundleURL,
        moduleFallback: () -> Bundle = { .module }
    ) -> Bundle {
        for base in [mainResourceURL, mainBundleURL].compactMap({ $0 }) {
            // `Bundle(url:)` already returns nil when nothing lives at the path,
            // so it doubles as the existence check.
            if let bundle = Bundle(url: base.appendingPathComponent(bundleName)) {
                return bundle
            }
        }
        return moduleFallback()
    }
}
