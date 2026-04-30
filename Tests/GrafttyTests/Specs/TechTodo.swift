// Auto-generated inventory of unimplemented specs in this section.
// Promote a @Test(.disabled(...)) entry to a real @Test in a *Tests.swift
// file before implementing the behavior, then delete the entry from this
// inventory file. SPECS.md is regenerated from these markers by
// scripts/generate-specs.py.

import Testing

@Suite("TECH — pending specs")
struct TechTodo {
    @Test("""
@spec TECH-1: The application shall be built in Swift using SwiftUI for app chrome and AppKit for terminal view hosting.
""", .disabled("not yet implemented"))
    func tech_1() async throws { }

    @Test("""
@spec TECH-2: The application shall use libghostty (via the libghostty-spm Swift Package) as its terminal engine.
""", .disabled("not yet implemented"))
    func tech_2() async throws { }

    @Test("""
@spec TECH-3: The application shall target macOS 14 Sonoma as its minimum supported version.
""", .disabled("not yet implemented"))
    func tech_3() async throws { }

    @Test("""
@spec TECH-4: The application shall reuse the following components from the Ghostty project (MIT-licensed): `SplitTree`, `SplitView`, `Ghostty.Surface`, `Ghostty.App`, `Ghostty.Config`, and `SurfaceView_AppKit`.
""", .disabled("not yet implemented"))
    func tech_4() async throws { }

    @Test("""
@spec TECH-5: The application shall invoke every external tool (`git`, `gh`, `glab`, `zmx`) with `LC_ALL=C` in the child environment so output parsers written against English strings (e.g. `git diff --shortstat` "insertion"/"deletion" markers, `gh pr checks` bucket names) keep working when the user's shell locale is non-English. This is a forcing function — the alternative (locale-robust parsers across multiple tools) is fragile and brittle.
""", .disabled("not yet implemented"))
    func tech_5() async throws { }
}
