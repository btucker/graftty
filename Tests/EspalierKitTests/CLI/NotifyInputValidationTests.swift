import Testing
@testable import EspalierKit

@Suite("NotifyInputValidation")
struct NotifyInputValidationTests {

    @Test func textOnlyIsValid() {
        let r = NotifyInputValidation.validate(text: "Build failed", clear: false)
        #expect(r == .valid)
        #expect(r.message == nil)
    }

    @Test func clearOnlyIsValid() {
        let r = NotifyInputValidation.validate(text: nil, clear: true)
        #expect(r == .valid)
    }

    @Test func neitherIsMissing() {
        let r = NotifyInputValidation.validate(text: nil, clear: false)
        #expect(r == .missingTextAndClear)
        #expect(r.message?.contains("--clear") == true)
    }

    @Test func bothIsConflict() {
        // The bug that triggered this: `espalier notify "Build failed" --clear`
        // previously exited 0. The text was dropped and the server received
        // just a clear. Andy's ambiguous input should error instead so he
        // notices the stale `--clear` in shell history.
        let r = NotifyInputValidation.validate(text: "Build failed", clear: true)
        #expect(r == .bothTextAndClear)
        #expect(r.message?.contains("Cannot combine") == true)
    }

    @Test func emptyStringWithClearIsStillAConflict() {
        // Empty-string + --clear: the ambiguity-of-intent problem from
        // `bothIsConflict` is the more useful thing to surface. Andy
        // typed something (probably from history); the empty-string
        // shape isn't what tripped him, the stray --clear is.
        let r = NotifyInputValidation.validate(text: "", clear: true)
        #expect(r == .bothTextAndClear)
    }

    @Test func emptyStringAloneIsInvalid() {
        // `espalier notify "$STATUS"` when `$STATUS` is unset expands to
        // `espalier notify ""`. Without the emptyText case, the server
        // would render an empty red capsule — a ghost attention the user
        // can't see or dismiss except by clicking.
        let r = NotifyInputValidation.validate(text: "", clear: false)
        #expect(r == .emptyText)
        #expect(r.message?.contains("empty") == true)
    }

    @Test func whitespaceOnlyTextIsInvalid() {
        // Spaces, tabs, newlines — all render as visually-empty badges.
        // Match trimmingCharacters(.whitespacesAndNewlines) semantics.
        for ws in ["   ", "\t", "\n", "  \t\n "] {
            let r = NotifyInputValidation.validate(text: ws, clear: false)
            #expect(r == .emptyText, "expected .emptyText for \(ws.debugDescription)")
        }
    }

    @Test func singleNonWhitespaceCharIsValid() {
        // Minimal meaningful input: a dot, a bullet, a single emoji.
        for c in [".", "·", "🔔", "!"] {
            let r = NotifyInputValidation.validate(text: c, clear: false)
            #expect(r == .valid, "expected .valid for \(c.debugDescription)")
        }
    }

    // --clear-after upper bound. A raw `Int?` accepts `9999999` (≈116d)
    // or `999999999` (~31y); the server schedules a Dispatch timer for
    // each, leaking main-queue entries for the lifetime of the session.
    // Cap at 24h — plenty for any CI / build / shell-integration flow.

    @Test func clearAfterBelowCapIsValid() {
        #expect(NotifyInputValidation.validate(text: "x", clear: false, clearAfter: 60) == .valid)
        #expect(NotifyInputValidation.validate(text: "x", clear: false, clearAfter: 86400) == .valid)
    }

    @Test func clearAfterAtZeroOrNegativeIsValid() {
        // Per STATE-2.8 the server treats ≤0 as "no auto-clear"; the CLI
        // defers to that contract rather than hard-erroring here.
        #expect(NotifyInputValidation.validate(text: "x", clear: false, clearAfter: 0) == .valid)
        #expect(NotifyInputValidation.validate(text: "x", clear: false, clearAfter: -1) == .valid)
    }

    @Test func clearAfterAboveCapIsRejected() {
        let r = NotifyInputValidation.validate(text: "x", clear: false, clearAfter: 86401)
        #expect(r == .clearAfterTooLarge(max: 86400))
        #expect(r.message?.contains("86400") == true)
    }

    @Test func clearAfterIsIgnoredWhenClearingExplicitly() {
        // `--clear --clear-after N` passes through only because a higher
        // priority error (bothTextAndClear / missingTextAndClear) is
        // about to fire anyway when combined with text. In the
        // text=nil + clear=true path, clearAfter is meaningless and
        // not inspected here; that ambiguity is a separate (future)
        // validation concern.
        #expect(NotifyInputValidation.validate(text: nil, clear: true, clearAfter: 9999999) == .valid)
    }

    @Test func nilClearAfterIsValid() {
        #expect(NotifyInputValidation.validate(text: "x", clear: false, clearAfter: nil) == .valid)
    }
}
