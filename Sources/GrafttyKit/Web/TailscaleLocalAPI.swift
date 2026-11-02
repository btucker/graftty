import Foundation
import NIOCore
import NIOPosix

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
public struct TailscaleLocalAPI: Sendable {

    /// Candidate Unix-socket paths, tried in order.
    public static let defaultSocketPaths: [String] = [
        "/var/run/tailscaled.socket",
        NSString(string: "~/Library/Containers/io.tailscale.ipn.macsys/Data/IPN/tailscaled.sock").expandingTildeInPath,
    ]

    /// Where the macsys (DMG) install publishes its TCP port + auth token.
    public static let defaultMacsysSupportDir: String = "/Library/Tailscale"

    public struct Status: Equatable, Sendable {
        public let loginName: String
        public let tailscaleIPs: [String]
        /// The machine's MagicDNS fully-qualified name, trailing dot
        /// stripped. `nil` when the tailnet has MagicDNS disabled or
        /// the response omits the field. Callers that need HTTPS
        /// cert provisioning treat `nil` as fatal (WEB-8.1).
        public let dnsName: String?
    }

    public struct Whois: Equatable, Sendable {
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
    enum Transport: Equatable, Sendable {
        case unixSocket(path: String)
        case tcpLocalhost(port: Int, authToken: String)
    }

    let transport: Transport
    private let channelOpened: (@Sendable (Channel) -> Void)?

    public init(socketPath: String) {
        self.transport = .unixSocket(path: socketPath)
        self.channelOpened = nil
    }

    init(transport: Transport, channelOpened: (@Sendable (Channel) -> Void)? = nil) {
        self.transport = transport
        self.channelOpened = channelOpened
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
    /// `recvTimeoutSeconds` bounds receive inactivity on the event loop.
    /// The 2 s default fits the WebServer auth hot path (`whois`, `status`);
    /// `certPair` overrides to a longer value because first-time
    /// Let's Encrypt minting can pause tailscaled for 10–30 s before
    /// the response starts streaming. WEB-8.5.
    private func transportCall(
        path: String,
        recvTimeoutSeconds: Int = 2
    ) async throws -> (Int, Data) {
        try Task.checkCancellation()
        if case .tcpLocalhost(let port, _) = transport, !(1...65535).contains(port) {
            throw Error.socketUnreachable
        }
        let requestState = LocalAPIRequestState()
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let response = loop.makePromise(of: Data.self)
        let handler = try await loop.submit {
            NIOLoopBound(LocalAPIResponseHandler(
                response: response, receiveTimeout: .seconds(Int64(recvTimeoutSeconds))
            ), eventLoop: loop)
        }.get()
        let authHeader: String
        switch transport {
        case .unixSocket:
            authHeader = "Basic Og=="
        case .tcpLocalhost(_, let token):
            authHeader = "Basic " + Data(":\(token)".utf8).base64EncodedString()
        }
        let request = "GET \(path) HTTP/1.0\r\nHost: local-tailscaled.sock\r\nAuthorization: \(authHeader)\r\nConnection: close\r\n\r\n"
        let buffer: Data
        do {
            buffer = try await withTaskCancellationHandler {
                let bootstrap = ClientBootstrap(group: loop)
                    .connectTimeout(.seconds(2))
                    .channelInitializer { channel in
                        return channel.pipeline.addHandler(handler.value).map {
                            requestState.install(channel)
                            channelOpened?(channel)
                        }
                    }
                let channel: Channel
                switch transport {
                case .unixSocket(let path):
                    channel = try await bootstrap.connect(unixDomainSocketPath: path).get()
                case .tcpLocalhost(let port, _):
                    channel = try await bootstrap.connect(
                        to: SocketAddress(ipAddress: "127.0.0.1", port: port)
                    ).get()
                }
                try Task.checkCancellation()
                var bytes = channel.allocator.buffer(capacity: request.utf8.count)
                bytes.writeString(request)
                try await channel.writeAndFlush(bytes).get()
                channel.pipeline.fireUserInboundEventTriggered(LocalAPIRequestSent())
                return try await response.futureResult.get()
            } onCancel: {
                requestState.cancel()
            }
        } catch {
            // Bootstrap may reject an address or fail to allocate a socket
            // before installing a handler. Settle its promise on every exit,
            // using the handler's event-loop-confined single-completion guard.
            try? await loop.submit { handler.value.fail(error) }.get()
            await requestState.close()
            try Task.checkCancellation()
            if error is Error { throw error }
            throw Error.socketUnreachable
        }
        await requestState.close()
        try Task.checkCancellation()

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

/// Owns a request's channel across the cancellation/initializer race. The
/// handler is event-loop confined; only channel installation needs a lock.
final class LocalAPIRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false

    func install(_ channel: Channel) {
        let shouldClose = lock.withLock {
            self.channel = channel
            return cancelled
        }
        if shouldClose { channel.close(promise: nil) }
    }

    func cancel() {
        let channel = lock.withLock {
            cancelled = true
            return self.channel
        }
        channel?.close(promise: nil)
    }

    func close() async {
        let channel = lock.withLock { self.channel }
        if let channel {
            try? await channel.close().get()
            try? await channel.closeFuture.get()
        }
    }
}

/// HTTP/1.0 responses end at EOF. Both the write and each read have bounded
/// waits, matching the former send/receive timeouts without blocking a thread.
struct LocalAPIRequestSent: Sendable {}

final class LocalAPIResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let response: EventLoopPromise<Data>
    private let receiveTimeout: TimeAmount
    private var bytes = Data()
    private var timeout: Scheduled<Void>?
    private var finished = false

    init(response: EventLoopPromise<Data>, receiveTimeout: TimeAmount) {
        self.response = response
        self.receiveTimeout = receiveTimeout
    }

    func channelActive(context: ChannelHandlerContext) {
        armTimeout(context: context, delay: .seconds(2), error: .socketUnreachable)
        context.fireChannelActive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is LocalAPIRequestSent {
            armTimeout(context: context, delay: receiveTimeout)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        finish(.failure(TailscaleLocalAPI.Error.socketUnreachable))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        bytes.append(contentsOf: chunk.readBytes(length: chunk.readableBytes) ?? [])
        armTimeout(context: context, delay: receiveTimeout)
    }

    private func armTimeout(
        context: ChannelHandlerContext,
        delay: TimeAmount,
        error: TailscaleLocalAPI.Error = .malformedResponse
    ) {
        guard !finished else { return }
        timeout?.cancel()
        timeout = context.eventLoop.scheduleTask(in: delay) {
            self.finish(.failure(error))
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.success(bytes))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Swift.Error) {
        finish(.failure(TailscaleLocalAPI.Error.malformedResponse))
        context.close(promise: nil)
    }

    func fail(_ error: any Swift.Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Data, any Swift.Error>) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        response.completeWith(result)
    }
}
