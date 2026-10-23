import NIO

public enum ServerBindError: Error, Equatable {
    /// The port is not a TCP port number (0–65535).
    case invalidPort(Int)
}

extension ServerBootstrap {
    /// Binds `host:port`, binding a numeric IP literal directly and resolving
    /// only a host name.
    ///
    /// NIO's `bind(host:port:)` resolves even `::` through `getaddrinfo`, and
    /// glibc's default `AI_ADDRCONFIG` rejects it on Linux hosts with no
    /// non-loopback IPv6 address, although the kernel serves a dual-stack
    /// listener there (#678). The port is checked first: the numeric
    /// `SocketAddress` initializer traps on an out-of-range port, and glibc
    /// resolves one such as 65536 to an ephemeral port instead of failing.
    public func bind(numericOrResolvedHost host: String, port: Int) throws -> EventLoopFuture<Channel> {
        guard (0...65_535).contains(port) else { throw ServerBindError.invalidPort(port) }
        if let address = try? SocketAddress(ipAddress: host, port: port) {
            return bind(to: address)
        }
        return bind(host: host, port: port)
    }
}
