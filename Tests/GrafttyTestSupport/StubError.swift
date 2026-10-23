/// An error for a test double to throw when only the failure matters, not
/// its kind.
public struct StubError: Error, Equatable {
    public init() {}
}
