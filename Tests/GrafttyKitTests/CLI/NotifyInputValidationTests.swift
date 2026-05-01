import Testing
@testable import GrafttyKit

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

    @Test("""
    @spec ATTN-1.6: If `graftty notify` is invoked with both a `<text>` argument and the `--clear` flag, then the CLI shall exit non-zero with a usage error rather than silently dropping the text and performing a clear.
    """)
    func bothIsConflict() {
        // The bug that triggered this: `graftty notify "Build failed" --clear`
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
        // `graftty notify "$STATUS"` when `$STATUS` is unset expands to
        // `graftty notify ""`. Without the emptyText case, the server
        // would render an empty red capsule — a ghost attention the user
        // can't see or dismiss except by clicking.
        let r = NotifyInputValidation.validate(text: "", clear: false)
        #expect(r == .emptyText)
        #expect(r.message?.contains("empty") == true)
    }

    @Test("""
    @spec ATTN-1.7: If `graftty notify` is invoked with text that is empty or contains only whitespace characters (including tabs and newlines), then the CLI shall exit non-zero with a usage error rather than sending a visually-empty attention badge.
    """)
    func whitespaceOnlyTextIsInvalid() {
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

    @Test("""
    @spec ATTN-1.8: If `graftty notify` is invoked with `--clear-after` greater than 86400 seconds (24 hours), then the CLI shall exit non-zero with a usage error. Values at or below 86400 are accepted; values at or below zero are handled server-side per `STATE-2.8`.
    """)
    func clearAfterAboveCapIsRejected() {
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

    @Test("""
    @spec ATTN-1.9: If `graftty notify` is invoked with both `--clear` and `--clear-after`, then the CLI shall exit non-zero with a usage error. `--clear-after` applies only to notify messages; combining it with `--clear` is ambiguous and previously resulted in the `--clear-after` value being silently dropped.
    """)
    func clearWithPositiveClearAfterIsRejected() {
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
    // sidebar row. Piping `git log` or `ls -la` into `graftty notify`
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

    @Test("""
    @spec ATTN-1.10: If `graftty notify` is invoked with text longer than 200 Character (grapheme cluster) units, then the CLI shall exit non-zero with a usage error. Attention overlays are designed for short status pings rendered in a narrow sidebar capsule; large inputs (e.g. a piped `git log` or `ls -la`) blow up layout and drown the intended signal.
    """)
    func textOneOverMaxIsRejected() {
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

    // ATTN-1.12: the sidebar capsule renders `Text(attentionText)` with
    // `.lineLimit(1)` + `.truncationMode(.tail)`. Any control character
    // (LF, CR, TAB, BEL, ESC, etc.) either clips the render or lands as
    // a literal glyph like `[31m` from an ANSI escape. Reject all
    // Cc-category scalars at the CLI so the user gets clear feedback.

    @Test("""
    @spec ATTN-1.12: If `graftty notify` is invoked with text containing any Unicode Cc (control) scalar — line feed, carriage return, tab, bell, ANSI escape, DEL, null byte, or any other C0/C1 control — then the CLI shall exit non-zero with a usage error reading "Notification text cannot contain control characters (newlines, tabs, ANSI escapes, or other non-printable characters)". The sidebar capsule renders `Text(attentionText)` with `.lineLimit(1)` + `.truncationMode(.tail)`; newlines clip to the first line, tabs render at implementation-defined width, and ANSI escape sequences like `\\e[31m` show up as literal glyphs (the ESC byte is invisible in SwiftUI Text, producing strings like `[31mred[0m`). All of those are data loss or visual garbage from the user's perspective. The server-side `Attention.isValidText` applies the same rejection (silently drops) as a backstop for raw socket clients (`nc -U`, web surface, custom scripts) bypassing the CLI.
    """)
    func textWithEmbeddedLineFeedIsInvalid() {
        let r = NotifyInputValidation.validate(text: "line1\nline2", clear: false)
        #expect(r == .controlCharactersInText)
        #expect(r.message?.contains("control characters") == true)
    }

    @Test func textWithEmbeddedCarriageReturnIsInvalid() {
        let r = NotifyInputValidation.validate(text: "line1\rline2", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func textWithCRLFIsInvalid() {
        let r = NotifyInputValidation.validate(text: "line1\r\nline2", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func textWithAnsiEscapeIsInvalid() {
        // Common: `ls --color=always | head | xargs graftty notify`
        // pipes text with ESC-based SGR codes. Rendering `[31mred[0m`
        // as literal text (ESC is invisible in SwiftUI Text) is a
        // visual defect — the user wanted color, got garbled string.
        let r = NotifyInputValidation.validate(text: "\u{001B}[31mred\u{001B}[0m", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func textWithTabIsInvalid() {
        let r = NotifyInputValidation.validate(text: "foo\tbar", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func textWithBellIsInvalid() {
        let r = NotifyInputValidation.validate(text: "\u{0007}ding", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func textWithNullByteIsInvalid() {
        let r = NotifyInputValidation.validate(text: "before\u{0000}after", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func textWithDeleteCharIsInvalid() {
        // DEL (0x7F) is a C0 control via general category.
        let r = NotifyInputValidation.validate(text: "foo\u{007F}bar", clear: false)
        #expect(r == .controlCharactersInText)
    }

    @Test func plainSinglelineTextStillValid() {
        // Regression guard: the widened check must not reject ordinary
        // single-line text.
        #expect(NotifyInputValidation.validate(text: "Build failed", clear: false) == .valid)
        #expect(NotifyInputValidation.validate(text: "✓ 42 tests", clear: false) == .valid)
    }

    @Test func nonControlUnicodeStillValid() {
        // Emoji, CJK, accented Latin — all outside the Cc category, all
        // legitimate notify text.
        #expect(NotifyInputValidation.validate(text: "🚀 deploy", clear: false) == .valid)
        #expect(NotifyInputValidation.validate(text: "日本語 テスト", clear: false) == .valid)
        #expect(NotifyInputValidation.validate(text: "café ✓", clear: false) == .valid)
    }

    @Test func trailingNewlineIsStillInvalid() {
        // A trailing `\n` (e.g. from `echo | xargs graftty notify`)
        // still counts as a control character — erroring here tells
        // the user what went wrong rather than silently clipping.
        let r = NotifyInputValidation.validate(text: "Build failed\n", clear: false)
        #expect(r == .controlCharactersInText)
    }

    // ATTN-1.13: text made entirely of Unicode Format-category (Cf)
    // scalars renders as a visually-empty badge — zero-width space,
    // zero-width joiner, byte-order mark, bidi overrides, etc. These
    // pass the whitespace-trim check (trimming doesn't strip Cf) and
    // the control-char check (Cf is distinct from Cc). Reject when
    // every non-whitespace scalar is Cf; accept when ANY scalar is
    // something else, so emoji sequences that embed ZWJ (U+200D) for
    // ligature remain valid.

    @Test("""
    @spec ATTN-1.13: If `graftty notify` is invoked with text whose scalars are entirely Unicode Format-category (Cf) and/or whitespace — e.g., `"\\u{FEFF}"` (BOM), `"\\u{200B}\\u{200C}\\u{FEFF}"` (mixed zero-width scalars) — then the CLI shall reject the message as `emptyText`. Swift's `whitespacesAndNewlines` trim strips some Cf scalars (ZWSP U+200B) but not others (BOM U+FEFF), producing a would-be zero-width badge; the extra allSatisfy check closes the gap. Mixed content that still carries at least one visible scalar (including ZWJ-joined emoji sequences like `👨‍👩‍👧`) remains valid. `Attention.isValidText` applies the same rejection server-side.
    """)
    func textOfOnlyZeroWidthSpaceIsInvalid() {
        // U+200B ZERO WIDTH SPACE — invisible, would render as blank.
        let r = NotifyInputValidation.validate(text: "\u{200B}", clear: false)
        #expect(r == .emptyText)
    }

    @Test func textOfOnlyBOMIsInvalid() {
        // U+FEFF ZERO WIDTH NO-BREAK SPACE / BOM.
        let r = NotifyInputValidation.validate(text: "\u{FEFF}", clear: false)
        #expect(r == .emptyText)
    }

    @Test func textOfMixedFormatScalarsIsInvalid() {
        // U+200B + U+200C + U+FEFF — all format-category, all invisible.
        let r = NotifyInputValidation.validate(text: "\u{200B}\u{200C}\u{FEFF}", clear: false)
        #expect(r == .emptyText)
    }

    @Test func formatScalarsBracketingContentAreValid() {
        // Mixed with visible content → accepted. User may have pasted
        // a Word-mangled string with trailing BOM; as long as *something*
        // renders, we pass it through.
        #expect(NotifyInputValidation.validate(text: "\u{200B}a", clear: false) == .valid)
        #expect(NotifyInputValidation.validate(text: "a\u{200B}b", clear: false) == .valid)
    }

    @Test func emojiWithZWJLigatureIsValid() {
        // U+200D ZERO WIDTH JOINER builds emoji sequences like family
        // emoji 👨‍👩‍👧 — the codepoints ARE Cf, but the ligature produces
        // a visible glyph. Mustn't reject.
        #expect(NotifyInputValidation.validate(text: "👨\u{200D}👩\u{200D}👧", clear: false) == .valid)
    }

    // ATTN-1.14: the BIDI-override scalars (U+202A-U+202E, U+2066-U+2069)
    // are Unicode Format-category (Cf) and so pass both the Cc-control
    // check (`.controlCharactersInText`) and the all-Cf invisibility
    // check (`.emptyText`) when interleaved with visible content. Result:
    // a notify like `\u{202E}evil\u{202C}` stores fine but renders with
    // reversed text in the sidebar — the "Trojan Source" style of
    // render distortion (CVE-2021-42574). Low-probability vector in
    // Andy's flow (he types his own notify text), but consistent with
    // ATTN-1.12's "reject surprising render distortion" principle.

    @Test("""
    @spec ATTN-1.14: If `graftty notify` is invoked with text containing any Unicode bidirectional-override scalar — the embedding family (`U+202A`–`U+202C`), the override family (`U+202D`–`U+202E`), or the isolate family (`U+2066`–`U+2069`) — then the CLI shall reject the message as `bidiControlInText` with the user-visible error "Notification text cannot contain bidirectional-override characters (U+202A-U+202E, U+2066-U+2069) — they visually reverse the text in the sidebar". These scalars are Unicode Format (Cf) so they slip past both `ATTN-1.12`'s Cc-control check and `ATTN-1.13`'s all-Cf-invisible check when mixed with visible content; a notify like `"\\u{202E}evil"` renders RTL-reversed in the sidebar capsule (the "Trojan Source" class of visual deception, CVE-2021-42574). RTL-natural text (Arabic, Hebrew) uses character-intrinsic directionality and does not use these override scalars, so it still validates cleanly. `Attention.isValidText` applies the same rejection server-side for raw socket clients that bypass the CLI.
    """)
    func textWithRLOOverrideIsInvalid() {
        // U+202E RIGHT-TO-LEFT OVERRIDE renders subsequent runs RTL.
        let r = NotifyInputValidation.validate(text: "\u{202E}evil", clear: false)
        #expect(r == .bidiControlInText)
    }

    @Test func textWithLRIIsolateIsInvalid() {
        // U+2066 LEFT-TO-RIGHT ISOLATE — the newer isolate family
        // (U+2066-U+2069) replaces the older embed family in security
        // advisories; we reject both.
        let r = NotifyInputValidation.validate(text: "ok\u{2066}hidden\u{2069}", clear: false)
        #expect(r == .bidiControlInText)
    }

    @Test func textWithLREEmbedIsInvalid() {
        // U+202A LEFT-TO-RIGHT EMBEDDING.
        let r = NotifyInputValidation.validate(text: "ok\u{202A}x\u{202C}", clear: false)
        #expect(r == .bidiControlInText)
    }

    @Test func plainNonBidiTextStillValid() {
        // Arabic / Hebrew / RTL-natural text doesn't USE the override
        // scalars; it just uses RTL-direction characters. Must pass.
        #expect(NotifyInputValidation.validate(text: "مرحبا", clear: false) == .valid)
        #expect(NotifyInputValidation.validate(text: "שלום world", clear: false) == .valid)
    }
}
