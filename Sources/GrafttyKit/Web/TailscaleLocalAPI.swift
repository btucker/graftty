import Foundation

/// Client for the Tailscale LocalAPI. Two install flavors, two transports:
///
/// - **OSS / App Store sandboxed:** LocalAPI is a Unix domain socket
///   (e.g., `/var/run/tailscaled.socket`). Auth is `Basic base64(":")`
///   — the socket is local, the user is implicit.
/// - **DMG "macsys" (Tailscale.app + system extension):** LocalAPI is
///   TCP on `127.0.0.1:<port>`. The port is published in
///   `/Library/Tailscale/ipnport` (typically a symlink whose target is
///   the decimal port) and the auth token is in
///   `/Library/Tailscale/sameuserproof-<port>` (root-owned, group
///   `admin`). Auth is `Basic base64(":<token>")`.
///
/// We call three endpoints:
///
/// - `GET /localapi/v0/status` — returns the local tailnet identity
///   (our LoginName), the TailscaleIPs assigned to this host, and
///   the machine's MagicDNS FQDN.
/// - `GET /localapi/v0/whois?addr=<ip>:<port>` — returns the
///   UserProfile of the tailnet peer at that address.
/// - `GET /localapi/v0/cert/<fqdn>?type=pair` — returns a Let's
///   Encrypt cert + key PEM pair Tailscale has minted for the
///   machine's MagicDNS name. Used to bind the HTTPS web server
///   (WEB-8.2). Requires the tailnet admin to have HTTPS
///   Certificates enabled in the admin console.
///
/// # Lifetime
/// Stateless. Each call opens + closes the transport.
///
/// # Failure policy
/// All failure modes throw. Callers are expected to treat any thrown
/// error as "deny" (fail-closed). The top-level `WebServer` never
/// binds without a successful `status()` call.
public struct TailscaleLocalAPI {

    /// Candidate Unix-socket paths, tried in order.
    public static let defaultSocketPaths: [String] = [
        "/var/run/tailscaled.socket",
        NSString(string: "~/Library/Containers/io.tailscale.ipn.macsys/Data/IPN/tailscaled.sock").expandingTildeInPath,
    ]

    /// Where the macsys (DMG) install publishes its TCP port + auth token.
    public static let defaultMacsysSupportDir: String = "/Library/Tailscale"

    public struct Status: Equatable {
        public let loginName: String
        public let tailscaleIPs: [String]
        /// The machine's MagicDNS fully-qualified name, trailing dot
        /// stripped. `nil` when the tailnet has MagicDNS disabled or
        /// the response omits the field. Callers that need HTTPS
        /// cert provisioning treat `nil` as fatal (WEB-8.1).
        public let dnsName: String?
    }

    public struct Whois: Equatable {
        public let loginName: String
    }

    public enum Error: Swift.Error, Equatable {
        case socketUnreachable
        case httpError(Int)
        case malformedResponse
        /// The tailnet admin has not enabled HTTPS Certificates. The
        /// caller surfaces a link to the admin console rather than a
        /// generic HTTP error code.
        case httpsCertsDisabled
    }

    /// Which transport to use for this client. `autoDetected()` picks
    /// one based on what's on disk; tests construct instances directly
    /// via `init(socketPath:)` (Unix) or the internal transport init.
    enum Transport: Equatable {
        case unixSocket(path: String)
        case tcpLocalhost(port: Int, authToken: String)
    }

    let transport: Transport

    public init(socketPath: String) {
        self.transport = .unixSocket(path: socketPath)
    }

    init(transport: Transport) {
        self.transport = transport
    }

    /// Auto-detect a reachable Tailscale LocalAPI endpoint. Probes Unix
    /// sockets first (fastest, matches OSS and the sandboxed app), then
    /// falls back to the macsys DMG's TCP LocalAPI. Throws
    /// `.socketUnreachable` if nothing usable is found.
    public static func autoDetected() throws -> TailscaleLocalAPI {
        try autoDetected(
            socketPaths: defaultSocketPaths,
            macsysSupportDir: defaultMacsysSupportDir
        )
    }

    /// Testable seam for `autoDetected()`. Injecting the candidate paths
    /// lets unit tests exercise both detection branches without touching
    /// real Tailscale state on disk.
    static func autoDetected(
        socketPaths: [String],
        macsysSupportDir: String
    ) throws -> TailscaleLocalAPI {
        for path in socketPaths where FileManager.default.fileExists(atPath: path) {
            return TailscaleLocalAPI(transport: .unixSocket(path: path))
        }
        if let tcp = detectMacsysTCP(supportDir: macsysSupportDir) {
            return TailscaleLocalAPI(transport: tcp)
        }
        throw Error.socketUnreachable
    }

    /// Read `<supportDir>/ipnport` (file or symlink) + the matching
    /// `sameuserproof-<port>` token. Returns `nil` — not throws — when
    /// the layout is incomplete, so `autoDetected` can fall through to
    /// its final `.socketUnreachable` error cleanly.
    static func detectMacsysTCP(supportDir: String) -> Transport? {
        let portPath = supportDir + "/ipnport"
        let portText: String
        if let link = try? FileManager.default.destinationOfSymbolicLink(atPath: portPath) {
            portText = link
        } else if let text = try? String(contentsOfFile: portPath, encoding: .utf8) {
            portText = text
        } else {
            return nil
        }
        guard let port = Int(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0..<65536).contains(port) else {
            // Out-of-range port → return nil so autoDetected falls
            // through to `.socketUnreachable` cleanly. Without the
            // range check, a corrupted `ipnport` or a future layout
            // change writing a larger number would store the bad
            // value in `.tcpLocalhost(port:)`; `openTCPLocalhost`'s
            // later `UInt16(port)` would then trap the whole app.
            return nil
        }
        let tokenPath = supportDir + "/sameuserproof-\(port)"
        guard let raw = try? String(contentsOfFile: tokenPath, encoding: .utf8) else {
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        return .tcpLocalhost(port: port, authToken: token)
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

    /// Fetch the cert + key PEM pair Tailscale has minted for this
    /// machine's MagicDNS name. Classifies "tailnet HTTPS disabled"
    /// into `.httpsCertsDisabled` so the Settings pane can render an
    /// admin-console deep link instead of an opaque 500. WEB-8.2.
    ///
    /// The 90 s recv timeout is sized for first-time Let's Encrypt
    /// minting — tailscaled runs an ACME DNS-01 exchange before the
    /// response starts streaming, which routinely takes 10–30 s and
    /// can run longer under nameserver hiccups. The 2 s default used
    /// for `whois`/`status` would silently truncate the response and
    /// surface as `.malformedResponse`. WEB-8.5.
    public func certPair(for fqdn: String) async throws -> (cert: Data, key: Data) {
        let escaped = fqdn.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fqdn
        let (code, body) = try await transportCall(
            path: "/localapi/v0/cert/\(escaped)?type=pair",
            recvTimeoutSeconds: 90
        )
        if code == 200 {
            return try Self.parseCertPair(body)
        }
        if Self.isHTTPSCertsDisabled(httpStatus: code, body: body) {
            throw Error.httpsCertsDisabled
        }
        throw Error.httpError(code)
    }

    // MARK: - Parsing (testable)

    static func parseStatus(_ data: Data) throws -> Status {
        struct RawStatus: Decodable {
            struct Me: Decodable {
                let UserID: Int?
                let TailscaleIPs: [String]?
                let DNSName: String?
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
        let trimmedDNS = me.DNSName
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .flatMap { $0.isEmpty ? nil : $0 }
        return Status(
            loginName: profile.LoginName,
            tailscaleIPs: me.TailscaleIPs ?? [],
            dnsName: trimmedDNS
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

    /// Split Tailscale's `application/x-pem-file` response into the
    /// cert-chain PEM and the private-key PEM. The response concatenates
    /// both blocks; Tailscale 1.96+ emits the key first and the cert
    /// chain after, but earlier versions (and the reverse ordering) are
    /// equally valid — so we locate the private-key block's BEGIN/END
    /// boundaries and treat everything outside it as the cert chain.
    /// Both halves are returned with their trailing newline intact so
    /// NIOSSL's PEM parser is happy. WEB-8.2.
    static func parseCertPair(_ data: Data) throws -> (cert: Data, key: Data) {
        guard let text = String(data: data, encoding: .utf8) else {
            throw Error.malformedResponse
        }
        // Matches `-----BEGIN PRIVATE KEY-----`, `-----BEGIN EC PRIVATE KEY-----`,
        // `-----BEGIN RSA PRIVATE KEY-----`, etc. The trailing `\n?` on the
        // END marker absorbs the separator so the cert-side slice doesn't
        // start with a stray newline.
        guard
            let keyBegin = text.range(
                of: "-----BEGIN [A-Z ]*PRIVATE KEY-----",
                options: .regularExpression
            ),
            let keyEnd = text.range(
                of: "-----END [A-Z ]*PRIVATE KEY-----\\n?",
                options: .regularExpression,
                range: keyBegin.upperBound..<text.endIndex
            )
        else {
            throw Error.malformedResponse
        }
        let keyText = String(text[keyBegin.lowerBound..<keyEnd.upperBound])
        let certText = String(text[..<keyBegin.lowerBound])
                     + String(text[keyEnd.upperBound...])
        // Require both BEGIN and END boundaries on the cert side so a
        // truncated response (recv hit EOF mid-cert) surfaces as a
        // typed `.malformedResponse` rather than an opaque NIOSSL
        // parse error downstream.
        if !certText.contains("-----BEGIN CERTIFICATE-----")
            || !certText.contains("-----END CERTIFICATE-----") {
            throw Error.malformedResponse
        }
        return (Data(certText.utf8), Data(keyText.utf8))
    }

    /// Recognise Tailscale's "HTTPS certificates are not enabled for
    /// this tailnet" response across plausible wordings. Any ≥400
    /// status whose body mentions both "HTTPS" and "enable" qualifies
    /// — the exact phrasing is not API-stable so a substring match
    /// beats parsing the JSON envelope. WEB-8.2.
    static func isHTTPSCertsDisabled(httpStatus: Int, body: Data) -> Bool {
        guard httpStatus >= 400 else { return false }
        guard let text = String(data: body, encoding: .utf8) else { return false }
        let lower = text.lowercased()
        return lower.contains("https") && lower.contains("enable")
    }

    // MARK: - HTTP (transport-agnostic framing)

    private func request(path: String) async throws -> Data {
        let (code, body) = try await transportCall(path: path)
        if code != 200 { throw Error.httpError(code) }
        return body
    }

    /// Open the socket, send the HTTP/1.0 request, parse the response
    /// framing, and return `(statusCode, body)` without throwing on a
    /// non-200. Callers that want to inspect an error body (e.g., the
    /// cert endpoint's "HTTPS disabled" response) go through this;
    /// the simpler `request(path:)` funnels through here too.
    ///
    /// `recvTimeoutSeconds` sets `SO_RCVTIMEO` for this call. The 2 s
    /// default fits the WebServer auth hot path (`whois`, `status`);
    /// `certPair` overrides to a longer value because first-time
    /// Let's Encrypt minting can pause tailscaled for 10–30 s before
    /// the response starts streaming. WEB-8.5.
    private func transportCall(
        path: String,
        recvTimeoutSeconds: Int = 2
    ) async throws -> (Int, Data) {
        let fd: Int32
        let hostHeader: String
        let authHeader: String
        switch transport {
        case .unixSocket(let socketPath):
            fd = try Self.openUnixSocket(path: socketPath)
            hostHeader = "local-tailscaled.sock"
            // Empty basic auth: user is implicit via the local socket.
            authHeader = "Basic Og=="
        case .tcpLocalhost(let port, let token):
            fd = try Self.openTCPLocalhost(port: port)
            hostHeader = "local-tailscaled.sock"
            let creds = Data(":\(token)".utf8).base64EncodedString()
            authHeader = "Basic \(creds)"
        }
        defer { close(fd) }

        // Send timeout stays short — the request payload is <200 bytes
        // and any send-side hang means tailscaled is unresponsive.
        // Recv timeout is per-call so cert minting can wait for Let's
        // Encrypt without affecting the auth-path defaults. WEB-8.5.
        var sendTimeout = timeval(tv_sec: 2, tv_usec: 0)
        var recvTimeout = timeval(tv_sec: recvTimeoutSeconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

        // HTTP/1.0 avoids Transfer-Encoding: chunked responses that the
        // macsys TCP LocalAPI emits for larger payloads (e.g., `status`).
        // We make one request per connection anyway, so we gain nothing
        // from 1.1 framing — 1.0 + Connection: close just works.
        let req = """
        GET \(path) HTTP/1.0\r
        Host: \(hostHeader)\r
        Authorization: \(authHeader)\r
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
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw Error.malformedResponse
        }
        return (code, Data(body))
    }

    private static func openUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw Error.socketUnreachable }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
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
        if rc != 0 {
            close(fd)
            throw Error.socketUnreachable
        }
        return fd
    }

    private static func openTCPLocalhost(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { throw Error.socketUnreachable }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, size)
            }
        }
        if rc != 0 {
            close(fd)
            throw Error.socketUnreachable
        }
        return fd
    }

    private static func findDoubleCRLF(in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        let base = data.startIndex
        for i in 0...(data.count - 4) {
            if data[base + i] == 0x0D, data[base + i + 1] == 0x0A,
               data[base + i + 2] == 0x0D, data[base + i + 3] == 0x0A {
                return i
            }
        }
        return nil
    }
}
