import Testing
@testable import GrafttyKit

// Mirrors `NotifyInputValidationTests` so CLI-side and server-side
// validation stay in sync. If the CLI drifts, the server is the
// backstop — and vice versa.
@Suite("Attention.isValidText")
struct AttentionTextValidationTests {
    @Test func nonEmptyIsValid() {
        #expect(Attention.isValidText("Build failed"))
        #expect(Attention.isValidText("·"))
        #expect(Attention.isValidText("🔔"))
    }

    @Test func emptyIsInvalid() {
        #expect(!Attention.isValidText(""))
    }

    @Test func whitespaceOnlyIsInvalid() {
        for ws in ["   ", "\t", "\n", "  \t\n "] {
            #expect(!Attention.isValidText(ws), "expected invalid for \(ws.debugDescription)")
        }
    }

    @Test func leadingTrailingWhitespaceOnContentIsValid() {
        // The helper only rejects pure whitespace. Content with padding
        // still makes it through — the UI doesn't strip it, but that's
        // a rendering choice rather than an input-hygiene policy.
        #expect(Attention.isValidText("  build done  "))
    }

    // Server-side text length mirror of ATTN-1.10 (CLI cap). A raw
    // socket client can still send 50KB through `nc -U`, web surface,
    // or custom script; `isValidText` is the server's single gate.

    @Test func textAtExactlyMaxLengthIsValid() {
        let s = String(repeating: "a", count: Attention.textMaxLength)
        #expect(Attention.isValidText(s))
    }

    @Test("""
    @spec STATE-2.10: When the application receives a `notify` message over the socket whose text is longer than 200 Character (grapheme cluster) units, the application shall silently drop the message rather than render or persist a blob the sidebar capsule cannot display cleanly. This backs up the CLI's `ATTN-1.10` validation for non-CLI socket clients (raw `nc -U`, web surface, custom scripts).
    """)
    func textOneOverMaxIsInvalid() {
        let s = String(repeating: "a", count: Attention.textMaxLength + 1)
        #expect(!Attention.isValidText(s))
    }

    @Test func hugeTextIsInvalid() {
        let s = String(repeating: "x", count: 50_000)
        #expect(!Attention.isValidText(s))
    }

    @Test func textMaxLengthShareOneSourceOfTruth() {
        // Tripwire: both surface caps that govern user-supplied text
        // size (CLI notify on one side, OSC 2 pane title on the other)
        // must read through to Attention.textMaxLength so a single
        // edit in Attention.swift keeps all three in lockstep. Drift
        // between them would either over-reject (rejecting valid-on-CLI
        // text that the server would accept) or under-reject (accepting
        // a title the sidebar can't render cleanly).
        #expect(NotifyInputValidation.textMaxLength == Attention.textMaxLength)
        #expect(PaneTitle.maxStoredLength == Attention.textMaxLength)
    }

    // ATTN-1.12 server-side backstop: a raw socket client that bypasses
    // the CLI can't ship text with control characters through either.
    // Widened in cycle 108 from just LF/CR to the full Unicode Cc
    // category (ANSI escapes, tabs, bells, DEL, null byte, etc.).
    @Test func bidiOverrideScalarsAreInvalid() {
        // Server-side mirror of ATTN-1.14: raw socket clients that
        // bypass the CLI can't ship a Trojan-Source-style notify past
        // `Attention.isValidText` either.
        #expect(!Attention.isValidText("\u{202E}evil"))       // RLO
        #expect(!Attention.isValidText("\u{202A}x\u{202C}"))  // LRE..PDF
        #expect(!Attention.isValidText("ok\u{2066}x\u{2069}")) // LRI..PDI
    }

    @Test func controlCharactersInTextAreInvalid() {
        #expect(!Attention.isValidText("line1\nline2"))
        #expect(!Attention.isValidText("line1\rline2"))
        #expect(!Attention.isValidText("line1\r\nline2"))
        #expect(!Attention.isValidText("Build failed\n"))
        #expect(!Attention.isValidText("\u{001B}[31mred\u{001B}[0m"))
        #expect(!Attention.isValidText("foo\tbar"))
        #expect(!Attention.isValidText("\u{0007}ding"))
        #expect(!Attention.isValidText("before\u{0000}after"))
        #expect(!Attention.isValidText("foo\u{007F}bar"))
    }

    @Test func nonControlUnicodeIsValid() {
        #expect(Attention.isValidText("🚀 deploy"))
        #expect(Attention.isValidText("日本語 テスト"))
        #expect(Attention.isValidText("café ✓"))
    }

    // ATTN-1.13 server-side backstop: text that's entirely format-
    // category (Cf) + whitespace is visually invisible. Swift's
    // `whitespacesAndNewlines` strips ZWSP but not BOM — without
    // the additional guard `"\u{FEFF}"` would pass.
    @Test func formatOnlyTextIsInvalid() {
        #expect(!Attention.isValidText("\u{200B}"))
        #expect(!Attention.isValidText("\u{FEFF}"))
        #expect(!Attention.isValidText("\u{200B}\u{200C}\u{FEFF}"))
    }

    @Test func formatScalarsMixedWithContentAreValid() {
        #expect(Attention.isValidText("\u{200B}a"))
        #expect(Attention.isValidText("a\u{200B}b"))
        #expect(Attention.isValidText("👨\u{200D}👩\u{200D}👧"))
    }
}

// Mirrors `NotifyInputValidationTests` clear-after cap behaviors —
// the CLI rejects out-of-range values at the front door (ATTN-1.8);
// the server clamps them silently as a backstop (STATE-2.9) so a raw
// socket client can't park a multi-year timer on the main queue.
@Suite("""
Attention.effectiveClearAfter

@spec STATE-2.9: If a notify request specifies an auto-clear duration greater than 86400 seconds (24 hours), then the application shall clamp the duration to 86400 seconds rather than schedule a timer that could leak onto the main queue for days or years. This backs up the CLI's `ATTN-1.8` validation for non-CLI socket clients.
""")
struct AttentionClearAfterTests {
    @Test func nilPassesThrough() {
        #expect(Attention.effectiveClearAfter(nil) == nil)
    }

    @Test("""
    @spec STATE-2.8: If a notify request specifies an auto-clear duration of zero or negative, then the application shall treat the notification as having no auto-clear timer (the overlay persists until cleared by the CLI or replaced by another notification).
    """)
    func zeroAndNegativeBecomeNil() {
        #expect(Attention.effectiveClearAfter(0) == nil)
        #expect(Attention.effectiveClearAfter(-1) == nil)
        #expect(Attention.effectiveClearAfter(-9999) == nil)
    }

    @Test func inRangePassesThrough() {
        #expect(Attention.effectiveClearAfter(1) == 1)
        #expect(Attention.effectiveClearAfter(300) == 300)
        #expect(Attention.effectiveClearAfter(86_400) == 86_400)
    }

    @Test func aboveCapIsClampedToMax() {
        #expect(Attention.effectiveClearAfter(86_401) == 86_400)
        #expect(Attention.effectiveClearAfter(9_999_999) == 86_400)
        // Pathological: no integer overflow even at very large values.
        #expect(Attention.effectiveClearAfter(.greatestFiniteMagnitude) == 86_400)
    }
}
