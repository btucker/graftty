import Foundation
import Testing
@testable import GrafttyKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct HostPOSIXTests {
    @Test("@spec REMOTE-23.4: When writing host control data, the application shall support both Unix sockets and regular file descriptors.")
    func writesSocketAndFile() throws {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, GrafttyPOSIX.streamSocket, 0, &pair) == 0)
        defer { pair.forEach { GrafttyPOSIX.close($0) } }
        let bytes = Array("hello".utf8)
        #expect(bytes.withUnsafeBytes { GrafttyPOSIX.write(pair[0], $0.baseAddress, $0.count) } == 5)
        var received = [UInt8](repeating: 0, count: 5)
        #expect(GrafttyPOSIX.read(pair[1], &received, received.count) == 5)
        #expect(received == bytes)

        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let fd = GrafttyPOSIX.open(path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        #expect(fd >= 0)
        defer { GrafttyPOSIX.close(fd); GrafttyPOSIX.unlink(path) }
        #expect(bytes.withUnsafeBytes { GrafttyPOSIX.write(fd, $0.baseAddress, $0.count) } == 5)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data(bytes))
    }

    @Test("@spec REMOTE-23.5: When a local host peer connects over a Unix socket, the application shall obtain its operating-system user ID.")
    func authenticatesLocalPeer() {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, GrafttyPOSIX.streamSocket, 0, &pair) == 0)
        defer { pair.forEach { GrafttyPOSIX.close($0) } }
        #expect(GrafttyPOSIX.peerUserID(pair[0]) == getuid())
        #expect(GrafttyPOSIX.peerUserID(-1) == nil)
    }

    @Test("@spec REMOTE-23.6: When opening instructions beneath an approved directory, the application shall reject symlinks in every path component and parent-directory traversal.")
    func refusesEscapingPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("safe"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("instructions".utf8).write(to: root.appendingPathComponent("safe/file"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "safe")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("safe/link").path, withDestinationPath: "file")
        let directory = GrafttyPOSIX.open(root.path, O_RDONLY | O_DIRECTORY)
        #expect(directory >= 0)
        defer { GrafttyPOSIX.close(directory) }
        let valid = GrafttyPOSIX.openBeneath(directoryFD: directory, relativePath: "safe/file")
        #expect(valid >= 0)
        GrafttyPOSIX.close(valid)
        for path in ["link/file", "safe/link", "../file", "/safe/file", "safe/../safe/file"] {
            #expect(GrafttyPOSIX.openBeneath(directoryFD: directory, relativePath: path) == -1)
        }
    }
}
