// Tests/GrafttyKitTests/Editor/EditorPreferenceTests.swift
import XCTest
@testable import GrafttyKit

final class EditorPreferenceTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        // Use a unique suite per test so leftover keys don't bleed across.
        let suite = "EditorPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    private struct StubProbe: ShellEnvProbe {
        let value: String?
        func value(forName name: String) -> String? { value }
    }

    func test_userPreferenceCli_winsOverShellEnv() {
        let defaults = makeDefaults()
        defaults.set("cli", forKey: EditorPreference.Keys.kind)
        defaults.set("nvim", forKey: EditorPreference.Keys.cliCommand)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "vim")
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "nvim"))
        XCTAssertEqual(resolved.source, .userPreference)
    }

    func test_userPreferenceApp_winsOverShellEnv() {
        let defaults = makeDefaults()
        let cursorURL = URL(fileURLWithPath: "/Applications/Cursor.app")
        defaults.set("app", forKey: EditorPreference.Keys.kind)
        defaults.set("com.todesktop.230313mzl4w4u92", forKey: EditorPreference.Keys.appBundleID)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "nvim"),
            bundleIDResolver: { id in id == "com.todesktop.230313mzl4w4u92" ? cursorURL : nil }
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .app(bundleURL: cursorURL))
        XCTAssertEqual(resolved.source, .userPreference)
    }

    func test_emptyKind_fallsThroughToShellEnv() {
        let defaults = makeDefaults()
        // editorKind unset

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "nvim")
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "nvim"))
        XCTAssertEqual(resolved.source, .shellEnv)
    }

    func test_kindCli_butEmptyCommand_fallsThroughToShellEnv() {
        let defaults = makeDefaults()
        defaults.set("cli", forKey: EditorPreference.Keys.kind)
        defaults.set("", forKey: EditorPreference.Keys.cliCommand)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "vim")
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "vim"))
        XCTAssertEqual(resolved.source, .shellEnv,
                       "Empty CLI field must fall through, not pin to empty cli")
    }

    func test_kindApp_butStaleBundleID_fallsThroughToShellEnv() {
        let defaults = makeDefaults()
        defaults.set("app", forKey: EditorPreference.Keys.kind)
        defaults.set("com.gone.app", forKey: EditorPreference.Keys.appBundleID)

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: "nvim"),
            bundleIDResolver: { _ in nil }  // bundle no longer installed
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "nvim"))
        XCTAssertEqual(resolved.source, .shellEnv)
    }

    func test_shellEnvUnset_fallsThroughToVi() {
        let defaults = makeDefaults()

        let pref = EditorPreference(
            defaults: defaults,
            shellEnvProbe: StubProbe(value: nil)
        )
        let resolved = pref.resolve()
        XCTAssertEqual(resolved.kind, .cli(command: "vi"))
        XCTAssertEqual(resolved.source, .defaultFallback)
    }

    func test_resolveIsCached_probeCalledOnce() {
        let defaults = makeDefaults()

        final class CountingProbe: ShellEnvProbe {
            var count = 0
            func value(forName name: String) -> String? {
                count += 1
                return "nvim"
            }
        }
        let probe = CountingProbe()
        let pref = EditorPreference(defaults: defaults, shellEnvProbe: probe)
        _ = pref.resolve()
        _ = pref.resolve()
        XCTAssertEqual(probe.count, 1, "Shell env should be probed once and cached")
    }
}
