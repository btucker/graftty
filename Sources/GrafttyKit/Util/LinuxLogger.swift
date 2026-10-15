#if os(Linux)
import Foundation

/// Preserve the shared os.Logger call sites and privacy annotations on Linux.
/// systemd collects stderr; unannotated interpolated values remain redacted.
struct Logger: Sendable {
    let subsystem: String
    let category: String

    func debug(_ message: Message) { }
    func info(_ message: Message) { write("info", message) }
    func notice(_ message: Message) { write("notice", message) }
    func warning(_ message: Message) { write("warning", message) }
    func error(_ message: Message) { write("error", message) }

    private func write(_ level: String, _ message: Message) {
        FileHandle.standardError.write(Data("[\(subsystem):\(category)] \(level): \(message.value)\n".utf8))
    }

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let value: String
        init(stringLiteral value: String) { self.value = value }
        init(stringInterpolation: StringInterpolation) { value = stringInterpolation.value }
        struct StringInterpolation: StringInterpolationProtocol {
            enum Privacy { case `public`, `private` }
            var value = ""
            init(literalCapacity: Int, interpolationCount: Int) { value.reserveCapacity(literalCapacity) }
            mutating func appendLiteral(_ literal: String) { value += literal }
            mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .private) {
                self.value += privacy == .public ? String(describing: value) : "<private>"
            }
        }
    }
}
#endif
