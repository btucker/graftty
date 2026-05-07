// Sources/GrafttyKit/Ports/LsofOutputParser.swift
import Foundation

public enum LsofOutputParser {
    public struct Row: Equatable, Sendable {
        public let processName: String
        public let pid: pid_t
        public let address: String
        public let port: UInt16
    }

    public static func parse(_ output: String) -> [Row] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
    }

    private static func parseLine(_ line: String) -> Row? {
        if line.hasPrefix("COMMAND") { return nil }
        let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count >= 9 else { return nil }
        guard let pid = pid_t(fields[1]) else { return nil }
        let processName = fields[0]
        guard let nameToken = fields.last(where: { $0.contains(":") }) else { return nil }
        guard let (address, port) = splitAddressPort(nameToken) else { return nil }
        return Row(processName: processName, pid: pid, address: address, port: port)
    }

    static func splitAddressPort(_ token: String) -> (String, UInt16)? {
        if token.hasPrefix("[") {
            guard let bracketEnd = token.firstIndex(of: "]") else { return nil }
            let address = String(token[token.index(after: token.startIndex)..<bracketEnd])
            let after = token.index(after: bracketEnd)
            guard after < token.endIndex, token[after] == ":" else { return nil }
            let portStr = token[token.index(after: after)...]
            guard let port = UInt16(portStr) else { return nil }
            return (address, port)
        }
        guard let colonIdx = token.lastIndex(of: ":") else { return nil }
        let address = String(token[..<colonIdx])
        let portStr = token[token.index(after: colonIdx)...]
        guard let port = UInt16(portStr) else { return nil }
        return (address, port)
    }
}
