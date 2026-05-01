import Darwin

/// Cheap runtime probe for whether the OS can currently allocate another PTY.
public enum PtyDeviceAvailability: Equatable {
    case available
    case unavailable

    public static func live() -> PtyDeviceAvailability {
        probe(
            openPTY: { posix_openpt(O_RDWR | O_NOCTTY) },
            grantPTY: { grantpt($0) },
            unlockPTY: { unlockpt($0) },
            closeFD: { Darwin.close($0) }
        )
    }

    static func probe(
        openPTY: () -> Int32,
        grantPTY: (Int32) -> Int32,
        unlockPTY: (Int32) -> Int32,
        closeFD: (Int32) -> Void
    ) -> PtyDeviceAvailability {
        let fd = openPTY()
        guard fd >= 0 else { return .unavailable }
        guard grantPTY(fd) == 0 else {
            closeFD(fd)
            return .unavailable
        }
        guard unlockPTY(fd) == 0 else {
            closeFD(fd)
            return .unavailable
        }
        closeFD(fd)
        return .available
    }
}
