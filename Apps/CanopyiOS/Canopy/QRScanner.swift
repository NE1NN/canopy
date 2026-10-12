@preconcurrency import AVFoundation
import SwiftUI
import UIKit

enum CameraAccess: Sendable {
    case unknown, allowed, denied, unavailable

    static var current: CameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .denied, .restricted: return .denied
        default: return .unknown
        }
    }

    static func request() async -> CameraAccess {
        guard current == .unknown else { return current }
        return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
    }
}

/// The camera, reporting each QR code it sees.
struct QRScanner: UIViewRepresentable {
    var found: @MainActor (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.start(found: found)
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    static func dismantleUIView(_ view: PreviewView, coordinator: ()) {
        view.stop()
    }

    final class PreviewView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "com.ne1nn.Canopy.Phone.camera")
        private var found: @MainActor (String) -> Void = { _ in }

        func start(found: @escaping @MainActor (String) -> Void) {
            self.found = found
            guard let camera = AVCaptureDevice.default(for: .video),
                let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
            else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
            let preview = layer as? AVCaptureVideoPreviewLayer
            preview?.session = session
            preview?.videoGravity = .resizeAspectFill
            queue.async { [session] in session.startRunning() }
        }

        func stop() {
            queue.async { [session] in session.stopRunning() }
        }

        nonisolated func metadataOutput(
            _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            let codes = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated {
                for code in codes { found(code) }
            }
        }
    }
}
