import Foundation

/// The parenthesized comm field can itself contain spaces and parentheses.
/// Fields following its final closing parenthesis have fixed procfs positions.
struct LinuxProcessStat {
    let pid: Int32
    let parentPID: Int32
    let terminalDevice: UInt32
    let startTicks: UInt64

    init?(_ text: String) {
        guard let open = text.firstIndex(of: "("), let end = text.lastIndex(of: ")"),
              open < end,
              let pid = Int32(text[..<open].trimmingCharacters(in: .whitespaces)), pid > 0
        else { return nil }
        let fields = text[text.index(after: end)...].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 20, fields[0].count == 1,
              let parent = Int32(fields[1]), parent >= 0,
              let tty = Int32(fields[4]),
              let start = UInt64(fields[19]) else { return nil }
        self.pid = pid
        parentPID = parent
        terminalDevice = UInt32(bitPattern: tty)
        startTicks = start
    }

    static func read(pid: Int32) -> Self? {
        guard pid > 0, let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let value = Self(text), value.pid == pid else { return nil }
        return value
    }
}
