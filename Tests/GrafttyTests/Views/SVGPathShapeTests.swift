import Testing
import SwiftUI
@testable import Graftty

@Suite("SVGPathParser — path-data parsing")
struct SVGPathParserTests {
    private func bounds(_ d: String) -> CGRect {
        SVGPathParser.parse(d).boundingRect
    }

    @Test("Absolute move/line/close")
    func absoluteMoveLine() {
        let rect = bounds("M0 0L10 0 10 10Z")
        #expect(abs(rect.minX - 0) < 0.001)
        #expect(abs(rect.minY - 0) < 0.001)
        #expect(abs(rect.width - 10) < 0.001)
        #expect(abs(rect.height - 10) < 0.001)
    }

    @Test("Relative commands accumulate from the current point")
    func relativeCommands() {
        let rect = bounds("m1 1l2 0 0 2z")
        #expect(abs(rect.minX - 1) < 0.001)
        #expect(abs(rect.minY - 1) < 0.001)
        #expect(abs(rect.maxX - 3) < 0.001)
        #expect(abs(rect.maxY - 3) < 0.001)
    }

    @Test("Negative sign and repeated decimal point both delimit numbers")
    func numberTokenization() {
        // "20.3.9814" must parse as x=20.3, y=.9814 — the second dot
        // starts a new number. "-5-5" must parse as two numbers.
        let rect = bounds("M20.3.9814L-5-5")
        #expect(abs(rect.minX - (-5)) < 0.001)
        #expect(abs(rect.minY - (-5)) < 0.001)
        #expect(abs(rect.maxX - 20.3) < 0.001)
        #expect(abs(rect.maxY - 0.9814) < 0.001)
    }

    @Test("Horizontal, vertical, cubic, and smooth-cubic commands")
    func curvesAndAxisLines() {
        let rect = bounds("M0 0H10V10C10 15 5 15 5 10S0 5 0 10z")
        #expect(abs(rect.minX - 0) < 0.001)
        #expect(abs(rect.maxX - 10) < 0.001)
        #expect(rect.maxY > 10) // the cubics bow below y=10
    }

    @Test("Arc command produces a half-circle of the expected extent")
    func arcCommand() {
        // Semicircle of radius 5 from (0,0) to (10,0),
        // largeArc=false sweep=true. In SVG y-down coordinates this
        // arc bows upward (toward negative y): the bounding box sits
        // at y in [-5, 0].
        let rect = bounds("M0 0A5 5 0 0 1 10 0")
        #expect(abs(rect.width - 10) < 0.01)
        #expect(abs(rect.height - 5) < 0.05)
        #expect(rect.maxY <= 0.001)  // bows above the chord (negative y)
        #expect(rect.minY < -4.9)
    }

    @Test("Large-arc flag selects the major semicircle bowing to the opposite side")
    func largeArcCommand() {
        // "M0 0A5 5 0 1 0 10 0": rx=ry=5, largeArc=true, sweep=false.
        // With these exact endpoints the only circle center is (5,0),
        // so both the small and the large arc are geometrically the
        // same semicircle — but sweep=false traverses it counter-
        // clockwise (in SVG y-down), bowing toward POSITIVE y (below
        // the chord), opposite to the sweep=true case above.
        let rectLarge = bounds("M0 0A5 5 0 1 0 10 0")
        let rectSmall = bounds("M0 0A5 5 0 0 1 10 0")  // existing test case

        // Width spans both endpoints regardless of arc direction.
        #expect(abs(rectLarge.width - 10) < 0.05)
        // Height reaches radius on the opposite (positive-y) side.
        #expect(abs(rectLarge.height - 5) < 0.05)
        // The two cases must bow to opposite sides.
        #expect(rectLarge.minY >= -0.001)   // bows below chord (positive y)
        #expect(rectSmall.maxY <= 0.001)    // bows above chord (negative y)
    }

    @Test("S command without a preceding cubic uses current point as reflected control")
    func smoothCubicFallback() {
        // "M5 5S10 10 15 5": S with no prior C/c/S/s — the SVG spec
        // says the first control point equals the current point (5,5).
        // With c1=(5,5) and c2=(10,10) the curve bows toward y>5
        // (positive y in SVG y-down = downward).
        let rect = bounds("M5 5S10 10 15 5")
        // x-extent runs from start (5) to end (15).
        #expect(abs(rect.minX - 5) < 0.001)
        #expect(abs(rect.maxX - 15) < 0.001)
        // Curve bows toward the (10,10) control point, so maxY > 5.
        #expect(rect.maxY > 5)
        // Call must terminate (no infinite loop).
    }

    @Test("Malformed trailing numbers after Z do not loop forever")
    func noProgressGuard() {
        // "M0 0 Z 5 5": after Z closes the subpath, the stray numbers
        // have no command to consume them. The parser must bail without
        // looping and produce the same result as plain "M0 0Z".
        let rectMalformed = bounds("M0 0 Z 5 5")
        let rectClean = bounds("M0 0Z")
        #expect(abs(rectMalformed.width - rectClean.width) < 0.001)
        #expect(abs(rectMalformed.height - rectClean.height) < 0.001)
    }
}

@Suite("SVGPathShape — viewBox scaling")
struct SVGPathShapeScalingTests {
    @Test("Path scales to the proposed rect")
    func scalesToRect() {
        let shape = SVGPathShape(pathData: "M0 0L16 0 16 16 0 16Z", viewBox: CGSize(width: 16, height: 16))
        let rect = shape.path(in: CGRect(x: 0, y: 0, width: 13, height: 13)).boundingRect
        #expect(abs(rect.width - 13) < 0.001)
        #expect(abs(rect.height - 13) < 0.001)
    }
}
