import SwiftUI

/// Minimal @AppStorage-backed settings model. Off by default; port
/// defaults to 8799.
@MainActor
final class WebAccessSettings: ObservableObject {
    @AppStorage var isEnabled: Bool
    @AppStorage var port: Int

    static let shared = WebAccessSettings()

    /// `store` defaults to `nil`, which `@AppStorage` resolves to the standard
    /// defaults. Tests pass an isolated suite so enabling Web Access does not
    /// leak into the test runner's `UserDefaults.standard`.
    init(store: UserDefaults? = nil) {
        _isEnabled = AppStorage(wrappedValue: false, "WebAccessEnabled", store: store)
        _port = AppStorage(wrappedValue: 8799, "WebAccessPort", store: store)
    }
}
