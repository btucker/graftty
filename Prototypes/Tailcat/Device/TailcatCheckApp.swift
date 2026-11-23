import SwiftUI

@main
struct TailcatCheckApp: App {
    var body: some Scene {
        WindowGroup { CheckView() }
    }
}

private struct CheckView: View {
    @State private var running = false
    @State private var result: TailcatDeviceCheck.Result?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Send 1 KiB between two Tailcat peers on this iPhone and verify that every byte comes back. The peers use the internet to find each other.")
                    Button("Run transport check") {
                        running = true
                        failed = false
                        result = nil
                        Task {
                            do { result = try await TailcatDeviceCheck.run() }
                            catch { failed = true }
                            running = false
                        }
                    }
                    .disabled(running)
                }
                if running {
                    ProgressView("Connecting and checking the echo…")
                } else if let result {
                    Section("Echo verified") {
                        LabeledContent("Route", value: result.route.capitalized)
                        LabeledContent("Bytes echoed", value: result.byteCount.formatted())
                        LabeledContent("Echo time", value: result.elapsed.formatted(.units(allowed: [.milliseconds], fractionalPart: .show(length: 2))))
                    }
                } else if failed {
                    Text("The check could not verify the echo. Check your internet connection and try again.")
                }
            }
            .navigationTitle("Tailcat Check")
        }
    }
}
