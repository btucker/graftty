import SwiftUI

/// Minimal @AppStorage-backed settings model. Off by default; port
/// defaults to 8799.
@MainActor
final class WebAccessSettings: ObservableObject {
    @AppStorage("WebAccessEnabled") var isEnabled: Bool = false
    @AppStorage("WebAccessPort") var port: Int = 8799

    static let shared = WebAccessSettings()
}
