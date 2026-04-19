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
}
