import Testing
@testable import EspalierKit

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

    @Test func textOneOverMaxIsInvalid() {
        let s = String(repeating: "a", count: Attention.textMaxLength + 1)
        #expect(!Attention.isValidText(s))
    }

    @Test func hugeTextIsInvalid() {
        let s = String(repeating: "x", count: 50_000)
        #expect(!Attention.isValidText(s))
    }

    @Test func textMaxLengthShareOneSourceOfTruth() {
        // Tripwire: the CLI's NotifyInputValidation.textMaxLength must
        // read through to Attention.textMaxLength so server-side and
        // CLI-side can never drift.
        #expect(NotifyInputValidation.textMaxLength == Attention.textMaxLength)
    }
}

// Mirrors `NotifyInputValidationTests` clear-after cap behaviors —
// the CLI rejects out-of-range values at the front door (ATTN-1.8);
// the server clamps them silently as a backstop (STATE-2.9) so a raw
// socket client can't park a multi-year timer on the main queue.
@Suite("Attention.effectiveClearAfter")
struct AttentionClearAfterTests {
    @Test func nilPassesThrough() {
        #expect(Attention.effectiveClearAfter(nil) == nil)
    }

    @Test func zeroAndNegativeBecomeNil() {
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
