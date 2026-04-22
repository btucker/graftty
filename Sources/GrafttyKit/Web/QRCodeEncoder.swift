import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Encodes a string as a QR-code `CIImage`. Returns nil if the input
/// is empty or the filter fails to produce output.
public enum QRCodeEncoder {
    public static func encode(_ string: String, size: CGFloat) -> CIImage? {
        guard !string.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, size / output.extent.width)
        return output.transformed(by: .init(scaleX: scale, y: scale))
    }
}
