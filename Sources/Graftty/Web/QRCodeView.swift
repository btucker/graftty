import CoreImage
import GrafttyKit
import SwiftUI

/// Renders a QR encoding of `text` at the given size, or a placeholder
/// when `text` is empty or the encoder fails.
struct QRCodeView: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Group {
            if let ciImage = QRCodeEncoder.encode(text, size: size),
               let cg = CIContext().createCGImage(ciImage, from: ciImage.extent) {
                Image(decorative: cg, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("QR code for \(text)")
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.secondary.opacity(0.15))
                    .overlay(Text("Unavailable").foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
    }
}
