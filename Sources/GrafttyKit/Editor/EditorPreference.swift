// Sources/GrafttyKit/Editor/EditorPreference.swift
import AppKit
import Foundation

/// What the layered lookup returned. The `kind` says what to do; the
/// `source` is captured so the Settings UI can display the resolution
/// chain ("currently using $EDITOR from shell: nvim") and tests can
/// assert which branch fired.
public struct ResolvedEditor: Equatable {
    public enum Kind: Equatable {
        case app(bundleURL: URL)
        case cli(command: String)
    }

    public enum Source: Equatable {
        case userPreference
        case shellEnv
        case defaultFallback
    }

    public let kind: Kind
    public let source: Source

    public init(kind: Kind, source: Source) {
        self.kind = kind
        self.source = source
    }
}

/// Layered lookup of the user's editor preference. Resolution order:
///   1. `UserDefaults` (set by the Settings pane).
///   2. `$EDITOR` from the user's login shell, captured once via the
///      injected `ShellEnvProbe`.
///   3. Hardcoded `vi` fallback.
///
/// Empty/missing fields at layer 1 (e.g., user picked "App" but never
/// chose one) fall through to layer 2 — the Settings UI is responsible
/// for not letting the user save a half-configured choice in the common
/// case, but the resolve logic is defensive against it.
///
/// The shell-env probe is cached on first `resolve()` call and re-used
/// for subsequent calls within the lifetime of this `EditorPreference`
/// instance.
public final class EditorPreference {

    public enum Keys {
        public static let kind         = "editorKind"          // "" | "app" | "cli"
        public static let appBundleID  = "editorAppBundleID"
        public static let cliCommand   = "editorCliCommand"
    }

    private let defaults: UserDefaults
    private let shellEnvProbe: ShellEnvProbe
    private let bundleIDResolver: (String) -> URL?
    private var cachedShellEditor: String??

    public init(
        defaults: UserDefaults = .standard,
        shellEnvProbe: ShellEnvProbe,
        bundleIDResolver: @escaping (String) -> URL? = { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        }
    ) {
        self.defaults = defaults
        self.shellEnvProbe = shellEnvProbe
        self.bundleIDResolver = bundleIDResolver
    }

    public func resolve() -> ResolvedEditor {
        switch defaults.string(forKey: Keys.kind) ?? "" {
        case "cli":
            if let cmd = defaults.string(forKey: Keys.cliCommand),
               !cmd.trimmingCharacters(in: .whitespaces).isEmpty {
                return ResolvedEditor(kind: .cli(command: cmd), source: .userPreference)
            }

        case "app":
            if let bundleID = defaults.string(forKey: Keys.appBundleID),
               !bundleID.isEmpty,
               let url = bundleIDResolver(bundleID) {
                return ResolvedEditor(kind: .app(bundleURL: url), source: .userPreference)
            }

        default:
            break
        }

        if let env = shellEditorValue(), !env.isEmpty {
            return ResolvedEditor(kind: .cli(command: env), source: .shellEnv)
        }

        return ResolvedEditor(kind: .cli(command: "vi"), source: .defaultFallback)
    }

    /// Cached value of the shell's `$EDITOR`. Exposed so the Settings UI
    /// can show the fallback value alongside the "Use $EDITOR from shell"
    /// radio row without spawning a second probe.
    public func shellEditorValue() -> String? {
        if let cached = cachedShellEditor { return cached }
        let probed = shellEnvProbe.value(forName: "EDITOR")
        cachedShellEditor = probed
        return probed
    }
}
