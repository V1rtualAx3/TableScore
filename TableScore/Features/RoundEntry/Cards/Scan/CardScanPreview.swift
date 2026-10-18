import AVFoundation
import SwiftUI
import UIKit

/// Aperçu en direct (`AVCaptureVideoPreviewLayer`), qui suit l'orientation de l'interface et la
/// transmet à la prise de vue.
struct CardScanPreview: UIViewRepresentable {
    let camera: CardScanCamera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.camera = camera
        view.previewLayer?.session = camera.session
        view.previewLayer?.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        view.isAccessibilityElement = false
        return view
    }

    /// Nouvelle mise en page : l'angle est réappliqué si la connexion n'existait pas encore.
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.setNeedsLayout()
    }

    final class PreviewView: UIView {
        var camera: CardScanCamera?
        private var appliedAngle: CGFloat?

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            let orientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
            let angle = CardScanCamera.rotationAngle(for: orientation)
            guard angle != appliedAngle else { return }
            if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
                appliedAngle = angle
            }
            camera?.setCaptureRotationAngle(angle)
        }
    }
}
