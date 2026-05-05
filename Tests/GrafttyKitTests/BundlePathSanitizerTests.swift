import Testing
import Foundation
@testable import GrafttyKit

@Suite("BundlePathSanitizer — pure logic")
struct BundlePathSanitizerTests {
    // The bundle's Contents/MacOS dir holds the GUI binary `Graftty`
    // (capital G). On case-insensitive filesystems (macOS APFS default),
    // a `graftty` lookup matches `Graftty`, so any PATH entry pointing at
    // Contents/MacOS hijacks the CLI invocation. The actual CLI lives at
    // Contents/Helpers/graftty (per `scripts/bundle.sh`).
    let bundleURL = URL(fileURLWithPath: "/Applications/Graftty.app")
    var macosDir: String { bundleURL.appendingPathComponent("Contents/MacOS").path }
    var helpersDir: String { bundleURL.appendingPathComponent("Contents/Helpers").path }

    /// @spec ATTN-4.2: When the application creates a terminal pane surface, the application shall override the spawned shell's `PATH` to a sanitized form that removes any entry equal to the bundle's `Contents/MacOS` directory and prepends the bundle's `Contents/Helpers` directory. Without this, the embedded libghostty's bundle-self-locating logic puts `Graftty.app/Contents/MacOS` on PATH, and on macOS's case-insensitive APFS volume `which graftty` resolves the lowercase lookup to the GUI binary `Graftty` (which silently exits `0` on unknown args, so `graftty --help` prints nothing). The override is exact-path equality — unrelated `Contents/MacOS` directories from other apps in the user's PATH are left alone.
    @Test func stripsBundleMacOSDirAndPrependsHelpers() {
        let input = "/usr/local/bin:\(macosDir):/usr/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == "\(helpersDir):/usr/local/bin:/usr/bin")
    }

    @Test func prependsHelpersEvenWhenMacOSAbsent() {
        // Even brew-installed users benefit: the cask symlink at
        // /opt/homebrew/bin/graftty points at Helpers/graftty, but
        // putting Helpers itself on PATH ahead of brew's bin makes the
        // CLI invocation work even if the symlink is missing.
        let input = "/usr/local/bin:/usr/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == "\(helpersDir):/usr/local/bin:/usr/bin")
    }

    @Test func isIdempotentWhenAlreadySanitized() {
        let input = "\(helpersDir):/usr/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == input)
    }

    @Test func movesHelpersToFrontIfPresentLater() {
        // If something else prepended a path between sanitization passes
        // (or a user manually inserted Helpers mid-PATH), move it to the
        // front so the CLI wins against any other graftty-named binary
        // that might have crept in.
        let input = "/usr/bin:\(helpersDir):/usr/local/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == "\(helpersDir):/usr/bin:/usr/local/bin")
    }

    @Test func removesAllOccurrencesOfMacOSDir() {
        // Defensive: a misconfigured user PATH could list the dir twice.
        // Both must go — leaving even one keeps the case-insensitive
        // collision in play.
        let input = "\(macosDir):/usr/bin:\(macosDir):/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == "\(helpersDir):/usr/bin:/bin")
    }

    @Test func handlesEmptyPath() {
        let result = BundlePathSanitizer.sanitized(currentPath: "", bundleURL: bundleURL)
        #expect(result == helpersDir)
    }

    @Test func preservesOtherEntriesAndOrder() {
        let input = "/a:/b:/c:\(macosDir):/d:/e"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == "\(helpersDir):/a:/b:/c:/d:/e")
    }

    @Test func doesNotStripUnrelatedMacOSStrings() {
        // A user dir named MacOS that is *not* this bundle's MacOS must
        // be left alone — the strip is exact-path only.
        let input = "/Users/btucker/projects/other.app/Contents/MacOS:/usr/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: bundleURL)
        #expect(result == "\(helpersDir):/Users/btucker/projects/other.app/Contents/MacOS:/usr/bin")
    }

    @Test func bundleWithDifferentLocationStillStripsAndPrepends() {
        // Dev builds run out of `.build/Graftty.app` rather than
        // `/Applications/Graftty.app`. The function shouldn't hardcode
        // the install location.
        let devBundle = URL(fileURLWithPath: "/tmp/build/Graftty.app")
        let devMacOS = "/tmp/build/Graftty.app/Contents/MacOS"
        let devHelpers = "/tmp/build/Graftty.app/Contents/Helpers"
        let input = "\(devMacOS):/usr/bin"
        let result = BundlePathSanitizer.sanitized(currentPath: input, bundleURL: devBundle)
        #expect(result == "\(devHelpers):/usr/bin")
    }
}
