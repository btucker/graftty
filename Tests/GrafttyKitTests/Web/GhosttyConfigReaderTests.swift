import Foundation
import Testing
@testable import GrafttyKit

struct GhosttyConfigReaderTests {
    @Test func preservesIncludedSettingsInGhosttyLoadOrderWithoutHostPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            "xdg": "font-size = 10\nconfig-file = \"included\"\n",
            "mac": "font-size = 12\nconfig-file = ?absent\n",
            "included": "font-family = Menlo\nfont-size = 16\nconfig-file = nested\n",
            "nested": "keybind = ctrl+a=select_all\nconfig-file = included\n"
        ]
        for (name, text) in files {
            try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let output = GhosttyConfigReader.portableConfig(paths: [
            directory.appendingPathComponent("xdg").path,
            directory.appendingPathComponent("mac").path
        ])
        #expect(output.contains("font-family = Menlo"))
        #expect(output.contains("keybind = ctrl+a=select_all"))
        #expect(!output.contains("config-file"))
        let sizes = output.split(separator: "\n").filter { $0.hasPrefix("font-size") }
        #expect(sizes == ["font-size = 10", "font-size = 12", "font-size = 16"])
    }
}
