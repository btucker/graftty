import Testing
import Foundation
@testable import GrafttyMobileKit

struct ChromeTabViewerTests {
    @Test("@spec CHROME-2.1: When a phone taps a fitted Chrome frame, the application shall map only image pixels to normalized browser coordinates and reject letterbox taps.")
    func mapsFittedImage() {
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 200, y: 400), in: CGSize(width: 400, height: 800)) == CGPoint(x: 0.5, y: 0.5))
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 200, y: 200), in: CGSize(width: 400, height: 800)) == nil)
        #expect(ChromeTabCoordinates.normalized(CGPoint(x: 0, y: 250), in: CGSize(width: 400, height: 800)) == CGPoint(x: 0, y: 0))
        #expect(ChromeTabCoordinates.normalized(.zero, in: .zero) == nil)
    }
}
