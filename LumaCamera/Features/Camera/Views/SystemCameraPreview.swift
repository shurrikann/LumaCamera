import SwiftUI
import AVFoundation
import UIKit

/// Apple's Cinematic sample renders the viewfinder with
/// `AVCaptureVideoPreviewLayer`. The layer consumes the session's baked
/// cinematic frames directly and does not depend on the recorder's video output.
struct SystemCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat
    let mirrored: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        update(view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session { uiView.previewLayer.session = session }
        update(uiView)
    }

    private func update(_ view: PreviewView) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(rotationAngle) {
            connection.videoRotationAngle = rotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
