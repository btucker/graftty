#if canImport(UIKit)
import Foundation
import Observation

/// Runtime tag carried in the APNs `userInfo` payload. Mirrors the
/// macOS-side `TeamHookRuntime` (in `GrafttyKit`) but is duplicated here
/// because `GrafttyMobileKit` deliberately does not depend on
/// `GrafttyKit` (which pulls in AppKit/Sparkle and other macOS-only
/// frameworks). The raw string values must stay in lockstep.
public enum DeepLinkRuntime: String, Sendable, Equatable {
    case claude
    case codex
}

/// Decoded representation of an `agent_stop` APNs banner payload —
/// enough to drive PUSH-4.1 navigation reconstruction.
public struct DeepLinkTarget: Equatable, Sendable {
    public let worktreePath: String
    public let sessionID: String
    public let runtime: DeepLinkRuntime

    public init(worktreePath: String, sessionID: String, runtime: DeepLinkRuntime) {
        self.worktreePath = worktreePath
        self.sessionID = sessionID
        self.runtime = runtime
    }
}

/// Receives banner taps from the `UNUserNotificationCenter` delegate and
/// publishes the decoded target to the SwiftUI view tree (PUSH-4.1).
/// When the app is locked at tap time (IOS-3.1), the target is queued
/// and only published once `unlockDidSucceed()` is called from
/// `BiometricGate`'s unlock flow (PUSH-4.2).
@MainActor
@Observable
public final class DeepLinkRouter {
    public static let shared = DeepLinkRouter()

    /// The published target. Observers (RootView) read this to drive
    /// navigation. They MUST call `consume()` after handling, otherwise
    /// re-renders would re-trigger the same deep link.
    public private(set) var pendingTarget: DeepLinkTarget?

    /// Held while the app is locked; flushed to `pendingTarget` by
    /// `unlockDidSucceed()`.
    private var queuedWhileLocked: DeepLinkTarget?

    public init() {}

    /// @spec PUSH-4.1
    /// Decode the userInfo payload and publish the target.
    /// @spec PUSH-4.2
    /// If the app is locked at tap time, queue and flush on
    /// `unlockDidSucceed()`.
    public func handleTap(userInfo: [AnyHashable: Any], isAppLocked: Bool) {
        guard let target = Self.decode(userInfo: userInfo) else { return }
        if isAppLocked {
            queuedWhileLocked = target
        } else {
            pendingTarget = target
        }
    }

    /// Called by `BiometricGate` (via RootView) once Face ID/Touch ID
    /// resolves successfully. Promotes any queued target to
    /// `pendingTarget` so the navigation observer fires.
    public func unlockDidSucceed() {
        if let queued = queuedWhileLocked {
            pendingTarget = queued
            queuedWhileLocked = nil
        }
    }

    /// Acknowledge handling — clears the slot so a re-render of the
    /// observing view doesn't loop on the same target.
    public func consume() {
        pendingTarget = nil
    }

    /// Pure decoder for the `agent_stop` APNs userInfo shape. Mirrors
    /// `AgentStopNotification.payload(from:)` on the macOS side. Returns
    /// `nil` for any malformed/unknown payload (including the silent
    /// `agent_stop_clear` kind, which is handled elsewhere by
    /// `PushReceiver`).
    static func decode(userInfo: [AnyHashable: Any]) -> DeepLinkTarget? {
        guard userInfo["kind"] as? String == "agent_stop",
              let runtimeRaw = userInfo["runtime"] as? String,
              let runtime = DeepLinkRuntime(rawValue: runtimeRaw),
              let worktreePath = userInfo["worktree_path"] as? String,
              let sessionID = userInfo["session_id"] as? String
        else {
            return nil
        }
        return DeepLinkTarget(
            worktreePath: worktreePath,
            sessionID: sessionID,
            runtime: runtime
        )
    }
}
#endif
