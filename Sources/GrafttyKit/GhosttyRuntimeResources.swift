import Foundation

/// Resolves the `GHOSTTY_RESOURCES_DIR` value libghostty reads at
/// `ghostty_init` time and spawn paths propagate to shells (CONFIG-2.x).
/// Graftty vendors ghostty's shell-integration scripts and terminfo into
/// GrafttyKit's SPM resource bundle (CONFIG-2.5,
/// `GhosttyResources/ghostty/PROVENANCE.md`), so resolution no longer
/// depends on a separately installed Ghostty.app.
public enum GhosttyRuntimeResources {
    /// How `GHOSTTY_RESOURCES_DIR` should be sourced. A pure decision value
    /// so the precedence rules are unit-testable without process-global
    /// `setenv` state.
    public enum Resolution: Equatable {
        /// CONFIG-2.2: the user's explicit env setting wins.
        case environmentOverride(String)
        /// CONFIG-2.3: point at the vendored copy in our bundle.
        case bundled(String)
        /// CONFIG-2.4: payload missing — caller warns, shells degrade
        /// gracefully (no OSC 7/133, TERM falls back per ZMX-6.5).
        case unavailable
    }

    /// The vendored `ghostty` resources dir inside GrafttyKit's module
    /// bundle, or nil when the payload is missing (mis-declared resource,
    /// corrupt install).
    public static func bundledResourcesDir() -> URL? {
        bundledResourcesDir(bundle: .module)
    }

    /// Test seam: resolve against an explicit bundle rather than .module.
    static func bundledResourcesDir(bundle: Bundle) -> URL? {
        guard let url = bundle.url(forResource: "ghostty", withExtension: nil),
              FileManager.default.fileExists(
                  atPath: url.appendingPathComponent("shell-integration").path
              )
        else { return nil }
        return url
    }

    /// Pure precedence decision (CONFIG-2.2 → CONFIG-2.3 → CONFIG-2.4).
    public static func resolve(
        processEnv: [String: String],
        bundledDir: URL?
    ) -> Resolution {
        if let existing = processEnv["GHOSTTY_RESOURCES_DIR"], !existing.isEmpty {
            return .environmentOverride(existing)
        }
        guard let bundledDir else { return .unavailable }
        return .bundled(bundledDir.path)
    }
}
