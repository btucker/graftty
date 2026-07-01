import Foundation
import Testing
import GrafttyKit
@testable import Graftty

/// Cold-boot regression: after a Mac restart, macOS relaunches Graftty during
/// session-restore *before* `tailscaled` has finished coming up, so the first
/// server bring-up attempt commonly lands on a transient dependency failure
/// (Tailscale daemon unreachable, MagicDNS name not yet published, or cert not
/// yet mintable). Before WEB-1.14 the reconcile path set a failure status and
/// returned with no retry, so the web server never came online until the user
/// manually toggled Web Access — which is exactly the "server didn't come back"
/// symptom this suite guards against.
@Suite("@spec WEB-1.14: While web access is enabled and the latest server bring-up attempt failed with a transient dependency error (Tailscale daemon unreachable, MagicDNS name not yet published, or certificate not yet mintable), the application shall automatically retry bring-up with capped exponential backoff until it succeeds or web access is disabled.")
struct WebServerControllerRetryTests {

    @Test func transientColdBootFailuresAreRetryable() {
        #expect(WebServerController.isTransientStartupFailure(.tailscaleUnavailable))
        #expect(WebServerController.isTransientStartupFailure(.magicDNSDisabled))
        #expect(WebServerController.isTransientStartupFailure(.certFetchFailed("acme exchange timed out")))
    }

    @Test func terminalAndSuccessStatusesAreNotRetried() {
        #expect(!WebServerController.isTransientStartupFailure(.stopped))
        #expect(!WebServerController.isTransientStartupFailure(.listening(addresses: ["100.64.0.1"], port: 8799)))
        #expect(!WebServerController.isTransientStartupFailure(.httpsCertsNotEnabled))
        #expect(!WebServerController.isTransientStartupFailure(.provisioningCert))
        #expect(!WebServerController.isTransientStartupFailure(.portUnavailable))
        #expect(!WebServerController.isTransientStartupFailure(.error("NIOBindError")))
    }

    @Test func backoffIsExponentialThenCapped() {
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .tailscaleUnavailable, attempt: 1) == 2)
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .tailscaleUnavailable, attempt: 2) == 4)
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .tailscaleUnavailable, attempt: 3) == 8)
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .tailscaleUnavailable, attempt: 4) == 16)
        // Capped so a tailnet that never recovers re-probes every 30s rather
        // than backing off to hours.
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .tailscaleUnavailable, attempt: 10) == 30)
    }

    @Test func terminalStatusYieldsNoRetryDelay() {
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .portUnavailable, attempt: 1) == nil)
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .error("boom"), attempt: 1) == nil)
        #expect(WebServerController.retryDelaySeconds(afterTransientFailure: .httpsCertsNotEnabled, attempt: 1) == nil)
    }
}
