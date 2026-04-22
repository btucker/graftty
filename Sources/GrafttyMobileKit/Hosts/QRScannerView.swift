#if canImport(UIKit)
import AVFoundation
import SwiftUI
import UIKit

public struct QRScannerView: UIViewControllerRepresentable {
    public let onDetect: (String) -> Void

    public init(onDetect: @escaping (String) -> Void) {
        self.onDetect = onDetect
    }

    public func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onDetect = onDetect
        return vc
    }

    public func updateUIViewController(_ vc: ScannerViewController, context _: Context) {
        vc.onDetect = onDetect
    }

    public final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onDetect: ((String) -> Void)?
        private let session = AVCaptureSession()
        private lazy var preview = AVCaptureVideoPreviewLayer(session: session)
        private var didDetect = false

        override public func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.metadataObjectTypes = [.qr]
            output.setMetadataObjectsDelegate(self, queue: .main)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.layer.bounds
            view.layer.addSublayer(preview)
            let captureSession = session
            Task.detached { captureSession.startRunning() }
        }

        override public func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview.frame = view.layer.bounds
        }

        override public func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            session.stopRunning()
        }

        public func metadataOutput(
            _: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from _: AVCaptureConnection
        ) {
            // AVFoundation fires this on every frame while a QR code is in
            // view — tens of times per second. Latch after the first hit so
            // we don't spawn N concurrent onDetect callbacks before SwiftUI
            // dismisses the sheet.
            guard !didDetect else { return }
            for obj in metadataObjects {
                if let readable = obj as? AVMetadataMachineReadableCodeObject,
                   let value = readable.stringValue {
                    didDetect = true
                    session.stopRunning()
                    onDetect?(value)
                    return
                }
            }
        }
    }
}
#endif
