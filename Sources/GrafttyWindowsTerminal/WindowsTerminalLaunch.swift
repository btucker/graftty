import Foundation

/// Win32 process parameters. Quoting follows CommandLineToArgvW and the C
/// runtime rules, not PowerShell or cmd.exe shell syntax.
public enum WindowsTerminalLaunch {
    public enum Error: Swift.Error, Equatable {
        case invalidArguments
        case commandLineTooLong
        case invalidEnvironment
    }

    public static func commandLine(arguments: [String]) throws -> String {
        guard let executable = arguments.first, !executable.isEmpty,
              arguments.allSatisfy({ !$0.utf16.contains(0) }) else { throw Error.invalidArguments }
        let command = arguments.map(quote).joined(separator: " ")
        // CreateProcessW includes the terminating UTF-16 null in this limit.
        guard command.utf16.count < 32_767 else { throw Error.commandLineTooLong }
        return command
    }

    private static func quote(_ argument: String) -> String {
        if !argument.isEmpty, !argument.unicodeScalars.contains(where: {
            $0.value == 0x22 || CharacterSet.whitespacesAndNewlines.contains($0)
        }) { return argument }
        var result = "\""
        var backslashes = 0
        for character in argument.unicodeScalars {
            if character.value == 0x5c {
                backslashes += 1
                continue
            }
            if character.value == 0x22 {
                result += String(repeating: "\\", count: backslashes * 2 + 1)
            } else {
                result += String(repeating: "\\", count: backslashes)
            }
            result.unicodeScalars.append(character)
            backslashes = 0
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    public static func environmentBlock(_ environment: [String: String]) throws -> [UInt16] {
        var names = Set<String>()
        for (name, value) in environment {
            guard !name.isEmpty, !name.contains("="), !name.utf16.contains(0), !value.utf16.contains(0),
                  names.insert(name.uppercased()).inserted else { throw Error.invalidEnvironment }
        }
        let keys = environment.keys.sorted { $0.uppercased() < $1.uppercased() }
        if keys.isEmpty { return [0, 0] }
        return Array((keys.map { "\($0)=\(environment[$0]!)\0" }.joined() + "\0").utf16)
    }
}
