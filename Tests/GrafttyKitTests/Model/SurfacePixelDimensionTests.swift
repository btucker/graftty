import Testing
import CoreGraphics
@testable import GrafttyKit

/// `SurfaceHandle.setFrameSize` used to do `UInt32(max(1, Int(dim)))` —
/// which TRAPS on `dim == .nan` or `dim == ±.infinity`. SwiftUI
/// `GeometryReader` has been observed to emit `.infinity` transiently
/// during certain rebinding flows, and a single trap on the main
/// thread takes out the whole app (every open pane dies). The helper
/// clamps those cases to safe values so the worst-case outcome is a
/// wrong-sized cell grid for one frame, not a process crash.
@Suite("SurfacePixelDimension.clamp")
struct SurfacePixelDimensionTests {

    @Test func nanClampsToOne() {
        // Pre-fix: `Int(CGFloat.nan)` traps the process; this test
        // wouldn't even complete. Post-fix: nil-free clamp returns 1.
        #expect(SurfacePixelDimension.clamp(.nan) == 1)
    }

    @Test func positiveInfinityClampsToUInt32Max() {
        #expect(SurfacePixelDimension.clamp(.infinity) == UInt32.max)
    }

    @Test func negativeInfinityClampsToOne() {
        #expect(SurfacePixelDimension.clamp(-.infinity) == 1)
    }

    @Test func zeroClampsToOne() {
        #expect(SurfacePixelDimension.clamp(0) == 1)
    }

    @Test func negativeClampsToOne() {
        #expect(SurfacePixelDimension.clamp(-100) == 1)
    }

    @Test func subUnitFractionClampsToOne() {
        // dim < 1 still rounds to 1; a zero-cell grid is nonsense.
        #expect(SurfacePixelDimension.clamp(0.5) == 1)
        #expect(SurfacePixelDimension.clamp(0.999) == 1)
    }

    @Test func typicalValuePassesThroughTruncated() {
        #expect(SurfacePixelDimension.clamp(1920) == 1920)
        #expect(SurfacePixelDimension.clamp(1920.75) == 1920) // truncation
    }

    @Test func exactlyOneStaysOne() {
        #expect(SurfacePixelDimension.clamp(1) == 1)
    }

    @Test func justUnderUInt32MaxTruncates() {
        // UInt32.max is 4_294_967_295. 4_294_967_295.0 as CGFloat
        // round-trips through Double; verify we don't accidentally
        // treat it as overflow.
        let big = CGFloat(UInt32.max - 100)
        #expect(SurfacePixelDimension.clamp(big) == UInt32.max - 100)
    }

    @Test func atUInt32MaxClampsToMax() {
        #expect(SurfacePixelDimension.clamp(CGFloat(UInt32.max)) == UInt32.max)
    }

    @Test func aboveUInt32MaxClampsToMax() {
        #expect(SurfacePixelDimension.clamp(CGFloat(UInt64.max)) == UInt32.max)
    }

    @Test func resizeProposalForwardsUsableSize() {
        let proposed = SurfacePixelDimension.resizeProposal(
            width: 1600,
            height: 900
        )

        #expect(proposed == SurfacePixelDimension.Size(width: 1600, height: 900))
    }

    @Test func resizeProposalIgnoresCollapsedSize() {
        let proposed = SurfacePixelDimension.resizeProposal(
            width: 0,
            height: 0
        )

        #expect(proposed == nil)
    }

    @Test func resizeProposalIgnoresCollapsedWidth() {
        let proposed = SurfacePixelDimension.resizeProposal(
            width: 0,
            height: 900
        )

        #expect(proposed == nil)
    }

    @Test func resizeProposalIgnoresSubUnitWidth() {
        let proposed = SurfacePixelDimension.resizeProposal(
            width: 0.5,
            height: 900
        )

        #expect(proposed == nil)
    }

    @Test func resizeProposalIgnoresCollapsedHeight() {
        let proposed = SurfacePixelDimension.resizeProposal(
            width: 1600,
            height: 0
        )

        #expect(proposed == nil)
    }

    @Test func resizeProposalForwardsUsableSizeAfterCollapsedProposal() {
        let proposed = SurfacePixelDimension.resizeProposal(
            width: 1400,
            height: 800
        )

        #expect(proposed == SurfacePixelDimension.Size(width: 1400, height: 800))
    }
}
