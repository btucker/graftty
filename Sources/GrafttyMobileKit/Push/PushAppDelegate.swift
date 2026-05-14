#if canImport(UIKit)
import UIKit
import UserNotifications

/// `@UIApplicationDelegateAdaptor`-installed delegate that owns the
/// `PushRegistrar` and bridges UIKit's APNs callbacks into it. The registrar
/// is constructed eagerly in `init` (rather than lazily in
/// `didFinishLaunchingWithOptions`) so the static handle is non-nil for any
/// caller that wants to trigger a re-register sweep from elsewhere (e.g. the
/// host-add flow). `HostStore.shared` is safe to read at delegate-init time
/// because `HostStore.init` performs no I/O.
@MainActor
public final class PushAppDelegate: NSObject, UIApplicationDelegate, @MainActor UNUserNotificationCenterDelegate {

    /// Static handle so non-AppDelegate surfaces (e.g. the "add host" sheet)
    /// can ask the registrar to fan out without plumbing it through the view
    /// hierarchy.
    public static var registrar: PushRegistrar?

    private let receiver = PushReceiver()

    public override init() {
        super.init()
        let registrar = PushRegistrar(
            hostSource: HostStorePushSource(HostStore.shared),
            network: URLSessionPushNetwork(),
            deviceName: UIDevice.current.name
        )
        Self.registrar = registrar
    }

    public func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let registrar = Self.registrar {
            Task { await registrar.requestAuthorizationAndRegister() }
        }
        return true
    }

    public func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard let registrar = Self.registrar else { return }
        Task {
            await registrar.deviceTokenDidArrive(token: hex)
            await registrar.registerWithAllHosts()
        }
    }

    public func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NSLog("PushAppDelegate: APNs registration failed: \(error)")
    }

    public func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task {
            let handled = await receiver.handleSilentPush(userInfo: userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// PUSH-4.1 / PUSH-4.2: routes a banner tap into `DeepLinkRouter`.
    /// The router decodes the payload and publishes a `DeepLinkTarget`
    /// that `RootView` observes to drive navigation reconstruction.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        Task { @MainActor in
            // TODO: wire iOS-3.1 lock state (BiometricGate) so a tap
            // while locked queues instead of publishing. The gate
            // currently lives in RootView's view-state; pulling it out
            // to a shared singleton (or threading it via a delegate
            // accessor) is a separate refactor. Defaulting to `false`
            // means a locked-tap target is published immediately — the
            // RootView observer still won't navigate behind the lock
            // overlay, so the user-visible behaviour is correct, just
            // not queued/re-applied on unlock.
            let locked = false
            DeepLinkRouter.shared.handleTap(userInfo: userInfo, isAppLocked: locked)
            completionHandler()
        }
    }
}
#endif
