import Foundation

/// @spec ATTN-2.19
/// When a control-socket request requires team inbox file I/O, the
/// application shall execute that work off the main thread so the main
/// actor stays free to serve concurrent control-socket requests and UI
/// events.
///
/// Team inbox operations parse the full `messages.jsonl` history and can
/// block up to `watermarkLockTimeout` on the inter-process watermark
/// lock. Handlers snapshot main-actor state first, then route the
/// file-backed work through `run`.
///
/// Backed by one dedicated serial queue rather than `Task.detached`: the
/// lock acquisition blocks its thread, and blocking on the cooperative
/// pool would let a burst of contended hooks starve unrelated async work.
/// Serial also matches the workload — these operations ultimately
/// serialize on the inter-process file lock anyway, so queueing them
/// avoids in-process contenders spinning on the same lock.
public enum OffMainIO {
    private static let queue = DispatchQueue(
        label: "com.graftty.off-main-io",
        qos: .userInitiated
    )

    public static func run<T: Sendable>(
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    public static func run<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: body())
            }
        }
    }
}
