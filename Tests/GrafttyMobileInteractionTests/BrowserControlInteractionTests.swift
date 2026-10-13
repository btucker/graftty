import UIKit
import XCTest

final class BrowserControlInteractionTests: XCTestCase {
    /// @spec CHROME-2.23: When the user taps the globe or its visible available-resource badge, the application shall invoke the same browser action.
    func testGlobeAndVisibleBadgeActivateTheSameControl() throws {
        for badge in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--browser-control-fixture"]
            app.launch()
            defer { app.terminate() }
            let browser = app.buttons["Browser"]
            XCTAssertTrue(browser.waitForExistence(timeout: 5))
            XCTAssertEqual(browser.value as? String, "1 available resources")
            let point: CGPoint
            if badge {
                // Use the displayed blue pixels, not an inferred button frame:
                // the badge extends into the label's top-right corner.
                point = try badgeCenter(in: app.screenshot().image, screen: app.frame, browser: browser.frame)
            } else {
                point = CGPoint(x: browser.frame.midX, y: browser.frame.midY)
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
            XCTAssertTrue(app.staticTexts["Activated"].waitForExistence(timeout: 3), badge ? "Visible badge tap must activate Browser" : "Globe center tap must activate Browser")
        }
    }

    private func badgeCenter(in image: UIImage, screen: CGRect, browser: CGRect) throws -> CGPoint {
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        var count = 0, xSum = 0, ySum = 0
        let region = browser.insetBy(dx: -12, dy: -12).intersection(screen)
        let minX = max(0, Int((region.minX - screen.minX) / screen.width * Double(cg.width)))
        let maxX = min(cg.width, Int(ceil((region.maxX - screen.minX) / screen.width * Double(cg.width))))
        let minY = max(0, Int((region.minY - screen.minY) / screen.height * Double(cg.height)))
        let maxY = min(cg.height, Int(ceil((region.maxY - screen.minY) / screen.height * Double(cg.height))))
        for y in minY..<maxY { for x in minX..<maxX {
            let index = (y * cg.width + x) * 4
            if Int(pixels[index + 2]) > Int(pixels[index]) + 40,
               Int(pixels[index + 2]) > Int(pixels[index + 1]) + 25 {
                count += 1; xSum += x; ySum += y
            }
        } }
        XCTAssertGreaterThan(count, 4, "The actual blue badge must be visible")
        guard count > 0 else { throw NSError(domain: "BrowserBadgeFixture", code: 1) }
        return CGPoint(x: screen.minX + Double(xSum) / Double(count * cg.width) * screen.width,
                       y: screen.minY + Double(ySum) / Double(count * cg.height) * screen.height)
    }
}
