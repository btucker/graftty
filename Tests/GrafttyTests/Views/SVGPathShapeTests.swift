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
        // Semicircle of radius 5 from (0,0) to (10,0).
        let rect = bounds("M0 0A5 5 0 0 1 10 0")
        #expect(abs(rect.width - 10) < 0.01)
        #expect(abs(rect.height - 5) < 0.05)
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
