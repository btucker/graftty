import Foundation
import Testing
@testable import GrafttyWindowsTerminal

struct WindowsTerminalLaunchTests {
    @Test("@spec TERM-13.1: When a native Windows terminal launches a process, the application shall preserve empty arguments, quotes, whitespace, and trailing backslashes in the Windows command line.")
    func arguments() throws {
        #expect(try WindowsTerminalLaunch.commandLine(arguments: ["tool.exe", "", "two words", "say\"hello", "C:\\two words\\"]) == #"tool.exe "" "two words" "say\"hello" "C:\two words\\""#)
        #expect(try WindowsTerminalLaunch.commandLine(arguments: ["tool.exe", "\"\u{301}"]) == "tool.exe \"\\\"\u{301}\"")
        #expect(try WindowsTerminalLaunch.commandLine(arguments: ["cmd.exe", "/D", "/C", "echo hello"]) == #"cmd.exe /D /C "echo hello""#)
        #expect(throws: WindowsTerminalLaunch.Error.self) {
            try WindowsTerminalLaunch.commandLine(arguments: ["tool.exe", "bad\0argument"])
        }
        #expect(throws: WindowsTerminalLaunch.Error.self) {
            try WindowsTerminalLaunch.commandLine(arguments: [])
        }
    }

    @Test("@spec TERM-13.2: When a native Windows terminal receives an environment, the application shall encode a sorted double-null-terminated UTF-16 block and reject case-insensitive duplicate names or embedded nulls.")
    func environment() throws {
        let block = try WindowsTerminalLaunch.environmentBlock(["Z": "last", "Path": "C:\\工具", "a": "first"])
        #expect(String(decoding: block, as: UTF16.self) == "a=first\0Path=C:\\工具\0Z=last\0\0")
        #expect(try WindowsTerminalLaunch.environmentBlock([:]) == [0, 0])
        for environment in [["Path": "a", "PATH": "b"], ["": "value"], ["BAD=NAME": "x"], ["A": "x\0y"], ["A\0B": "x"]] {
            #expect(throws: WindowsTerminalLaunch.Error.self) {
                try WindowsTerminalLaunch.environmentBlock(environment)
            }
        }
    }

    @Test("@spec TERM-13.3: If a native Windows terminal launch exceeds the Win32 command-line limit, then the application shall reject the launch before creating a process.")
    func commandLineLimit() throws {
        #expect(throws: WindowsTerminalLaunch.Error.self) {
            try WindowsTerminalLaunch.commandLine(arguments: [String(repeating: "x", count: 32_767)])
        }
        #expect(throws: WindowsTerminalLaunch.Error.self) {
            try WindowsTerminalLaunch.commandLine(arguments: [String(repeating: "🐈", count: 16_384)])
        }
        #expect(try WindowsTerminalLaunch.commandLine(arguments: [String(repeating: "x", count: 32_766)]).utf16.count == 32_766)
    }
}
