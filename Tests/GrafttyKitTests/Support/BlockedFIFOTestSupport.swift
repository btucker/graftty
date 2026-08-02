import Darwin
import Foundation

/// Gives subprocess-timeout regression fixtures an independent escape path.
///
/// The tested Git child blocks opening the FIFO for reading. If timeout
/// delivery breaks, this delayed nonblocking writer releases that read so the
/// test records its failed expectation instead of wedging the test process.
enum BlockedFIFOTestSupport {
    static func scheduleRelease(
        of fifoPath: String,
        // GCD timeout delivery has slipped by ~29 seconds under the full
        // parallel test load. Keep this independent escape hatch below the
        // tests' one-minute limit without racing a merely delayed real timer.
        after delay: Duration = .seconds(45)
    ) -> Task<Void, Never> {
        Task.detached {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }

            let descriptor = fifoPath.withCString {
                Darwin.open($0, O_WRONLY | O_NONBLOCK)
            }
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }

            let headContents = Array("ref: refs/heads/main\n".utf8)
            headContents.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                _ = Darwin.write(descriptor, baseAddress, bytes.count)
            }
        }
    }
}
