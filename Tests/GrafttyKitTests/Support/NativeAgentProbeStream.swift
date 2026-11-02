import Foundation
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class NativeAgentProbeStream {
    let child: DuplexSubprocess
    var buffer = Data()
    init(child: DuplexSubprocess) { self.child = child }
    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try child.input.write(contentsOf: data)
    }
    func receive(matching: ([String: Any]) -> Bool) throws -> [String: Any] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                if matching(message) { return message }
            }
            var descriptor = pollfd(fd: child.output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let result = poll(&descriptor, 1, 100)
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw RemoteSkillError("Agent discovery polling failed") }
            if result == 0 { continue }
            var bytes = [UInt8](repeating: 0, count: 65536)
            let count = GrafttyPOSIX.read(descriptor.fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RemoteSkillError("Agent exited before discovery completed") }
            guard buffer.count + count <= 4 * 1024 * 1024 else { throw RemoteSkillError("Agent discovery response exceeds limit") }
            buffer.append(contentsOf: bytes.prefix(count))
        }
        throw RemoteSkillError("Agent discovery timed out")
    }
}
