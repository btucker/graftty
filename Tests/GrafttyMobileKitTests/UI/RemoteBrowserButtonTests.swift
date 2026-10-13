#if canImport(UIKit)
import SwiftUI
import Testing
import UIKit
@testable import GrafttyMobileKit

@Suite(.serialized)
@MainActor
struct RemoteBrowserButtonTests {
    @Test("@spec CHROME-2.18: While the terminal browser control is visible, the application shall use the same primary glyph, plain button and translucent circle styling as Back while preserving its available-resource badge, busy indication and accessibility.", arguments: [0, 3])
    func browserUsesSharedFloatingStyle(availableCount: Int) async throws {
        let image = try await render(RemoteOpenButton.floatingControl(
            availableCount: availableCount, isBusy: false, action: {}), name: "browser-\(availableCount)")
        let pixels = try glyphPixels(image)
        if availableCount == 0 {
            let back = try await render(TerminalFloatingGlyphButton(
                systemName: "chevron.left", accessibilityLabel: "Back", action: {}), name: "back")
            let reference = try glyphPixels(back)
            #expect(pixels.blue == reference.blue)
            #expect(reference.visible >= 4)
        }
        #expect(pixels.blue == 0, "Browser glyph must use Back's primary foreground, not accent blue")
        #expect(pixels.visible >= 4, "The rendered globe must be visible")
        #expect(availableCount == 0 ? pixels.totalBlue == 0 : pixels.totalBlue >= 4,
                "Only a nonempty resource badge uses the accent tint")
    }

    @Test("The busy browser control keeps its shared foreground and resource badge")
    func busyControlKeepsSharedForeground() async throws {
        let image = try await render(RemoteOpenButton.floatingControl(
            availableCount: 3, isBusy: true, action: {}), name: "browser-busy")
        let pixels = try glyphPixels(image)
        #expect(pixels.blue == 0)
        #expect(pixels.visible >= 4, "The busy indicator must be visible")
        #expect(pixels.totalBlue >= 4, "The resource badge remains visible while busy")
    }

    private func render(_ button: some View, name: String) async throws -> UIImage {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let parent = UIViewController()
        parent.view.backgroundColor = .black
        window.rootViewController = parent
        window.makeKeyAndVisible()
        let host = UIHostingController(rootView: button.padding(14).frame(width: 72, height: 72)
            .environment(\.colorScheme, .dark).tint(.blue))
        parent.addChild(host)
        parent.view.addSubview(host.view)
        host.view.frame = CGRect(x: 20, y: 100, width: 72, height: 72)
        host.didMove(toParent: parent)
        host.view.backgroundColor = .black
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            #expect(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("graftty-browser-control-renders")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        return image
    }

    private func glyphPixels(_ image: UIImage) throws -> (blue: Int, visible: Int, totalBlue: Int) {
        let cgImage = try #require(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        var blue = 0, visible = 0, totalBlue = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            if Int(bytes[index + 2]) > Int(bytes[index]) + 40,
               Int(bytes[index + 2]) > Int(bytes[index + 1]) + 25 { totalBlue += 1 }
        }
        // Ignore the deliberately tinted resource badge outside the glyph.
        for y in 26..<47 { for x in 26..<43 {
            let index = (y * cgImage.width + x) * 4
            let red = Int(bytes[index]), green = Int(bytes[index + 1]), value = Int(bytes[index + 2])
            if value > red + 40, value > green + 25 { blue += 1 }
            if max(red, green, value) > 130 { visible += 1 }
        } }
        return (blue, visible, totalBlue)
    }
}
#endif
