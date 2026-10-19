import CoreGraphics
import Foundation
import Testing

@Suite("Native agent color observations")
struct AgentIntegrationColorTests {
    @Test("@spec TEST-1.9: When a native integration color probe runs, the test harness shall require chromatic rendered pixels on the current stream stage's inline-code, link, syntax, deletion, and addition rows, and shall reject missing or monochrome samples.")
    func colorSamplesBelongToTheirFixtureRows() throws {
        let width = 32, height = 12
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            for col in 0..<width {
                let offset = (row * width + col) * 4
                let green: [UInt8] = row >= 4 ? [50, 220, 80, 255] : [180, 180, 180, 255]
                rgba.replaceSubrange(offset..<(offset + 4), with: green)
            }
        }
        let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let samples = AgentIntegrationColorProbe.counts(image: image,
            physicalRows: "COLOR_INLINE\nunrelated colored row\nCOLOR_STRING", cellHeight: 4)
        #expect(samples["COLOR_INLINE"] == 0)
        #expect(samples["COLOR_STRING"] == width * 4)
        #expect(samples["COLOR_LINK"] == -1)
        let streamed = AgentIntegrationColorProbe.counts(image: image,
            physicalRows: "COLOR_INLINE_STREAMED\nunrelated colored row\nCOLOR_INLINE", cellHeight: 4,
            markerSuffix: "_STREAMED")
        #expect(streamed["COLOR_INLINE"] == 0)
        #expect(AgentIntegrationColorProbe.counts(image: image, physicalRows: "COLOR_LINK", cellHeight: 0)["COLOR_LINK"] == -1)
    }
}
