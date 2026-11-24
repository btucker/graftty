import Foundation
import ImageIO
import Testing

struct AppIconPackagingTests {
    @Test("@spec DIST-1.11: When packaging the macOS app icon, the build shall supply PNG-backed small icon representations so macOS can display 16-point and 32-point icons without a gray frame around the artwork.")
    func smallIconsUsePNGRepresentations() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("AppIcon.icns")
        let process = Process()
        process.executableURL = root.appendingPathComponent("scripts/build-icon.sh")
        process.arguments = [output.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)

        let data = try Data(contentsOf: output)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "icns")
        var chunks: [String: Data] = [:]
        var offset = 8
        while offset < data.count {
            try #require(offset + 8 <= data.count)
            let kind = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let length = data[(offset + 4)..<(offset + 8)].reduce(0) { ($0 << 8) | Int($1) }
            try #require(length >= 8 && length <= data.count - offset)
            chunks[kind] = data.subdata(in: (offset + 8)..<(offset + length))
            offset += length
        }

        // iconutil encodes the 1x 16/32 slots as ARGB. macOS gives these a
        // gray frame; PNG-backed Retina slots also cover standard density.
        #expect(chunks["ic04"] == nil)
        #expect(chunks["ic05"] == nil)
        for (kind, size) in [("ic11", 32), ("ic12", 64)] {
            let png = try #require(chunks[kind])
            #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == size)
            #expect(image.height == size)
        }
        #expect(chunks["ic10"] != nil, "Keep the full 1024-pixel representation")
    }
}
