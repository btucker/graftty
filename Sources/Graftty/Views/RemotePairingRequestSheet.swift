import SwiftUI

struct RemotePairingRequestSheet: View {
    let request: PendingRemotePairingRequest
    let onAccept: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 28))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Remote Mac Pairing")
                        .font(.headline)
                    Text(request.clientDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Verification Code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(request.verificationCode.display)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button(role: .cancel, action: onDeny) {
                    Label("Deny", systemImage: "xmark")
                }
                Button(action: onAccept) {
                    Label("Accept", systemImage: "checkmark")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 360)
    }
}
