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

    @Test func nilClearAfterIsValid() {
        #expect(NotifyInputValidation.validate(text: "x", clear: false, clearAfter: nil) == .valid)
    }

    // `--clear --clear-after <n>` was accepted pre-fix and the
    // `clearAfter` value silently dropped — the CLI's run() body took
    // the `.clear` branch and never read it. Reject: `--clear-after`
    // only applies to notify messages, and a user writing both is
    // ambiguous enough to warrant feedback rather than a mute
    // "did what you meant" guess.

    @Test func clearWithPositiveClearAfterIsRejected() {
        let r = NotifyInputValidation.validate(text: nil, clear: true, clearAfter: 30)
        #expect(r == .clearAfterWithClearFlag)
        #expect(r.message?.contains("--clear-after") == true)
        #expect(r.message?.contains("--clear") == true)
    }

    @Test func clearWithZeroOrNegativeClearAfterIsRejected() {
        // Even "harmless" values signal an ambiguous invocation. No
        // implicit "that's the same as bare --clear" fallback.
        #expect(NotifyInputValidation.validate(text: nil, clear: true, clearAfter: 0) == .clearAfterWithClearFlag)
        #expect(NotifyInputValidation.validate(text: nil, clear: true, clearAfter: -1) == .clearAfterWithClearFlag)
    }

    @Test func clearAloneWithoutClearAfterStaysValid() {
        // Regression: the happy path for `--clear` (no text, no
        // clearAfter) must keep passing through.
        #expect(NotifyInputValidation.validate(text: nil, clear: true, clearAfter: nil) == .valid)
    }

    // Attention text is rendered in a small red capsule on a narrow
    // sidebar row. Piping `git log` or `ls -la` into `espalier notify`
    // produces a KB-sized blob that blows up layout, stresses
    // persistence, and reduces signal-to-noise for the "one short
    // status ping" use case the UI is designed for.

    @Test func textAtExactlyMaxLengthIsValid() {
        let maxLen = NotifyInputValidation.textMaxLength
        let str = String(repeating: "a", count: maxLen)
        #expect(str.count == maxLen)
        let r = NotifyInputValidation.validate(text: str, clear: false)
        #expect(r == .valid)
    }

    @Test func textOneOverMaxIsRejected() {
        let maxLen = NotifyInputValidation.textMaxLength
        let str = String(repeating: "a", count: maxLen + 1)
        let r = NotifyInputValidation.validate(text: str, clear: false)
        #expect(r == .textTooLong(max: maxLen))
        #expect(r.message?.contains("\(maxLen)") == true)
    }

    @Test func textLengthUsesGraphemeClusters() {
        // Each flag emoji is one Character (several UTF-8 bytes /
        // multiple scalars). If we accidentally counted bytes, the
        // message would be orders-of-magnitude stricter than intended.
        let oneFlag = "🇺🇸"
        #expect(oneFlag.count == 1)
        let maxLen = NotifyInputValidation.textMaxLength
        let atMax = String(repeating: oneFlag, count: maxLen)
        #expect(NotifyInputValidation.validate(text: atMax, clear: false) == .valid)
        let overMax = atMax + "a"
        #expect(NotifyInputValidation.validate(text: overMax, clear: false) == .textTooLong(max: maxLen))
    }

    @Test func hugeTextIsRejected() {
        let huge = String(repeating: "x", count: 50_000)
        #expect(NotifyInputValidation.validate(text: huge, clear: false) == .textTooLong(max: NotifyInputValidation.textMaxLength))
    }

    @Test func textTooLongOverridesEmpty() {
        // Precedence: emptyText fires only for actually-empty strings,
        // so textTooLong never competes. Sanity: short empty still
        // returns emptyText.
        #expect(NotifyInputValidation.validate(text: "", clear: false) == .emptyText)
    }
}
