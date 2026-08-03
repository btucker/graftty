import Foundation
import Darwin

/// Loop-and-retry write helper for file descriptors: loops on partial
/// writes, retries on EINTR, throws on other errors.
public enum SocketIO {

    public struct CappedRead: Sendable, Equatable {
        public let data: Data
        public let exceededCap: Bool

        public init(data: Data, exceededCap: Bool) {
            self.data = data
            self.exceededCap = exceededCap
        }
    }

    public enum WriteError: Error, Equatable {
        case writeFailed(errno: Int32)
    }

    public static func writeAll(
        fd: Int32,
        bytes: UnsafePointer<UInt8>,
        count: Int
    ) throws {
        var offset = 0
        while offset < count {
            let n = Darwin.write(fd, bytes.advanced(by: offset), count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw WriteError.writeFailed(errno: errno)
            }
            if n == 0 {
                // Zero without an error is unusual on sockets, but
                // treat as EPIPE-equivalent rather than spinning
                // indefinitely.
                throw WriteError.writeFailed(errno: EPIPE)
            }
            offset += n
        }
    }

    /// Convenience wrapper that writes the UTF-8 bytes of a `String`
    /// (without a trailing terminator).
    public static func writeAll(fd: Int32, string: String) throws {
        let bytes = Array(string.utf8)
        try bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            try writeAll(fd: fd, bytes: base, count: buf.count)
        }
    }

    /// Read from `fd` until EOF or accumulated bytes reach `cap`.
    /// Never returns more than `cap` bytes. `SO_RCVTIMEO` bounds time
    /// per chunk; `cap` bounds total bytes so a misbehaving or compromised
    /// peer can't OOM the reader by flooding faster than the idle timeout
    /// fires. Call `readCapped` when truncation must be distinguished from
    /// an exact-size response.
    public static func readAll(fd: Int32, cap: Int) -> Data {
        readUpTo(fd: fd, limit: cap)
    }

    /// Reads at most `cap` bytes into the returned payload, plus one probe
    /// byte used only to distinguish an exact-size response from a response
    /// truncated at the safety limit. This lets callers report a size error
    /// instead of handing partial JSON to a decoder.
    public static func readCapped(fd: Int32, cap: Int) -> CappedRead {
        guard cap >= 0 else { return CappedRead(data: Data(), exceededCap: false) }
        let probeLimit = cap == Int.max ? cap : cap + 1
        var buffer = readUpTo(fd: fd, limit: probeLimit)
        let exceededCap = buffer.count > cap
        if exceededCap {
            buffer.removeSubrange(cap..<buffer.count)
        }
        return CappedRead(data: buffer, exceededCap: exceededCap)
    }

    private static func readUpTo(fd: Int32, limit: Int) -> Data {
        guard limit > 0 else { return Data() }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while buffer.count < limit {
            let toRead = min(chunk.count, limit - buffer.count)
            let n = Darwin.read(fd, &chunk, toRead)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer
    }
}
