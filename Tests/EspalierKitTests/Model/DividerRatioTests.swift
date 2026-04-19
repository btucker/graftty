import Testing
import CoreGraphics
@testable import EspalierKit

@Suite("DividerRatio — pure ratio math")
struct DividerRatioTests {
    // Regression: before TERM-4.2 was tightened, the divider's DragGesture
    // attached to a 4pt-wide Rectangle with the default `.local` coordinate
    // space, so `value.location.x` was measured inside the divider itself
    // (range ~0..4) rather than in the container. The resulting ratio
    // collapsed to minRatio on every click. These tests pin the math to
    // a container-space position so the SwiftUI layer can be audited
    // against them.

    @Test func midContainerProducesHalfRatio() {
        let r = DividerRatio.ratio(
            position: 500,
            total: 1000,
            minRatio: 0.1,
            maxRatio: 0.9
        )
        #expect(abs(r - 0.5) < 1e-9)
    }

    @Test func offCenterTracksPosition() {
        let r = DividerRatio.ratio(
            position: 300,
            total: 1000,
            minRatio: 0.1,
            maxRatio: 0.9
        )
        #expect(abs(r - 0.3) < 1e-9)
    }

    @Test func belowLowerBoundClamps() {
        // The old bug's fingerprint: 2 points in a 1000-wide container would
        // yield 0.002, which here clamps up to the 0.1 floor.
        let r = DividerRatio.ratio(
            position: 2,
            total: 1000,
            minRatio: 0.1,
            maxRatio: 0.9
        )
        #expect(abs(r - 0.1) < 1e-9)
    }

    @Test func aboveUpperBoundClamps() {
        let r = DividerRatio.ratio(
            position: 9999,
            total: 1000,
            minRatio: 0.1,
            maxRatio: 0.9
        )
        #expect(abs(r - 0.9) < 1e-9)
    }

    @Test func negativePositionClamps() {
        let r = DividerRatio.ratio(
            position: -10,
            total: 1000,
            minRatio: 0.1,
            maxRatio: 0.9
        )
        #expect(abs(r - 0.1) < 1e-9)
    }

    @Test func zeroTotalReturnsMinRatio() {
        let r = DividerRatio.ratio(
            position: 500,
            total: 0,
            minRatio: 0.1,
            maxRatio: 0.9
        )
        #expect(abs(r - 0.1) < 1e-9)
    }
}
