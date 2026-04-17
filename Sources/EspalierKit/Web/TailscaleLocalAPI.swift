import Foundation

/// Client for the Tailscale LocalAPI served on a Unix domain socket by
/// the Tailscale daemon. We call two endpoints only:
///
/// - `GET /localapi/v0/status` — returns the local tailnet identity
///   (our LoginName) and the TailscaleIPs assigned to this host.
/// - `GET /localapi/v0/whois?addr=<ip>:<port>` — returns the
///   UserProfile of the tailnet peer at that address.
///
/// # Lifetime
/// Stateless. Each call opens + closes the Unix socket.
///
/// # Failure policy
/// All failure modes throw. Callers are expected to treat any thrown
/// error as "deny" (fail-closed). The top-level `WebServer` never
/// binds without a successful `status()` call.
public struct TailscaleLocalAPI {

    /// Candidate Unix-socket paths, tried in order. The first path
    /// reachable is used; later calls do not re-probe — the caller
    /// is expected to stop/restart the server if Tailscale moves.
    public static let defaultSocketPaths: [String] = [
        "/var/run/tailscaled.socket",
        NSString(string: "~/Library/Containers/io.tailscale.ipn.macsys/Data/IPN/tailscaled.sock").expandingTildeInPath,
    ]

    public struct Status: Equatable {
        public let loginName: String
        public let tailscaleIPs: [String]
    }

    public struct Whois: Equatable {
        public let loginName: String
    }

    public enum Error: Swift.Error, Equatable {
        case socketUnreachable
        case httpError(Int)
        case malformedResponse
    }

    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// Construct using the first reachable default path. Throws
    /// `.socketUnreachable` if none are reachable.
    public static func autoDetected() throws -> TailscaleLocalAPI {
        for path in defaultSocketPaths where FileManager.default.fileExists(atPath: path) {
            return TailscaleLocalAPI(socketPath: path)
        }
        throw Error.socketUnreachable
    }

    // MARK: - Public API

    public func status() async throws -> Status {
        let body = try await request(path: "/localapi/v0/status")
        return try Self.parseStatus(body)
    }

    public func whois(peerIP: String) async throws -> Whois {
        // LocalAPI expects host:port; we don't know the peer port and
        // the API accepts port=0 for "any".
        let escaped = peerIP.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? peerIP
        let body = try await request(path: "/localapi/v0/whois?addr=\(escaped):0")
        return try Self.parseWhois(body)
    }

    // MARK: - Parsing (testable)

    static func parseStatus(_ data: Data) throws -> Status {
        struct RawStatus: Decodable {
            struct Me: Decodable {
                let UserID: Int?
                let TailscaleIPs: [String]?
            }
            struct UserProfile: Decodable {
                let LoginName: String
            }
            let `Self`: Me?
            let User: [String: UserProfile]?
        }
        let decoder = JSONDecoder()
        let raw = try decoder.decode(RawStatus.self, from: data)
        guard
            let me = raw.Self,
            let userID = me.UserID,
            let profile = raw.User?["\(userID)"]
        else {
            throw Error.malformedResponse
        }
        return Status(
            loginName: profile.LoginName,
            tailscaleIPs: me.TailscaleIPs ?? []
        )
    }

    static func parseWhois(_ data: Data) throws -> Whois {
        struct Raw: Decodable {
            struct UP: Decodable { let LoginName: String }
            let UserProfile: UP
        }
        let decoder = JSONDecoder()
        let raw = try decoder.decode(Raw.self, from: data)
        return Whois(loginName: raw.UserProfile.LoginName)
    }

    // MARK: - HTTP over Unix socket

    private func request(path: String) async throws -> Data {
        // We implement the minimum HTTP/1.1 framing needed: a single GET,
        // read headers until CRLFCRLF, then body by Content-Length.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw Error.socketUnreachable }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw Error.socketUnreachable
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                _ = pathBytes.withUnsafeBufferPointer { src in
                    memcpy(dst, src.baseAddress, src.count)
                }
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }
        if rc != 0 { throw Error.socketUnreachable }

        // Tailscale LocalAPI expects Basic auth with no password — the
        // user is implicit because the socket is local. An empty auth
        // header works for the documented endpoints.
        let req = """
        GET \(path) HTTP/1.1\r
        Host: local-tailscaled.sock\r
        Authorization: Basic Og==\r
        Connection: close\r
        \r\n
        """
        let reqBytes = Array(req.utf8)
        let sent = reqBytes.withUnsafeBufferPointer { buf in
            Darwin.send(fd, buf.baseAddress, buf.count, 0)
        }
        if sent != reqBytes.count { throw Error.socketUnreachable }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBufferPointer { buf in
                Darwin.recv(fd, buf.baseAddress, buf.count, 0)
            }
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }

        // Split headers + body.
        guard let split = Self.findDoubleCRLF(in: buffer) else {
            throw Error.malformedResponse
        }
        let headerText = String(data: buffer.prefix(split), encoding: .utf8) ?? ""
        let body = buffer.suffix(from: split + 4)

        // Parse status line.
        let firstLine = headerText.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2, let code = Int(parts[1]), code != 200 {
            throw Error.httpError(code)
        }

        return Data(body)
    }

    private static func findDoubleCRLF(in data: Data) -> Int? {
        let marker: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        let bytes = Array(data)
        guard bytes.count >= 4 else { return nil }
        for i in 0...(bytes.count - 4) where Array(bytes[i..<(i+4)]) == marker {
            return i
        }
        return nil
    }
}
