import AVFoundation
import CoreGraphics
import ImageIO
import SwiftUI
import UIKit

/// Appareil photo arrière pour le prototype P2 « Scanner les cartes ».
///
/// - Session `AVCaptureSession` + sortie photo **en mémoire** : aucune vidéo, aucun son, aucun
///   fichier, aucune photothèque ; la session est arrêtée dès la photo prise (voyant éteint).
/// - Toute manipulation de la session passe par une **file série dédiée** (jamais le main
///   thread) : c'est ce confinement qui justifie `@unchecked Sendable`.
/// - L'autorisation est demandée par `CardScanModel`, au premier usage seulement.
final class CardScanCamera: NSObject, @unchecked Sendable {
    enum Failure: Error, Equatable {
        case unavailable
        case configurationFailed
        case captureFailed
        case cancelled
    }

    /// Session partagée avec l'aperçu (`AVCaptureVideoPreviewLayer`).
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "app.tablescore.cardscan.camera")

    // État confiné à `queue`.
    private var isConfigured = false
    private var captureRotationAngle: CGFloat = 90
    private var pendingCapture: CheckedContinuation<CapturedPhoto, any Error>?

    /// Appareil photo arrière présent (faux sur simulateur).
    static var isHardwareAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
        #endif
    }

    /// Configure (une seule fois) puis démarre la session.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Arrête la session et abandonne une prise de vue en cours.
    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.pendingCapture?.resume(throwing: Failure.cancelled)
            self.pendingCapture = nil
        }
    }

    /// Angle de rotation à appliquer à la photo (suivi de l'orientation de l'interface).
    func setCaptureRotationAngle(_ angle: CGFloat) {
        queue.async {
            self.captureRotationAngle = angle
        }
    }

    /// Prend une photo, gardée en mémoire uniquement.
    func capturePhoto() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedPhoto, any Error>) in
            queue.async {
                guard self.session.isRunning, self.pendingCapture == nil else {
                    continuation.resume(throwing: Failure.captureFailed)
                    return
                }
                self.pendingCapture = continuation
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(self.captureRotationAngle) {
                    connection.videoRotationAngle = self.captureRotationAngle
                }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                self.output.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    /// Exécuté sur `queue`.
    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw Failure.unavailable
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw Failure.configurationFailed
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw Failure.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .balanced
        isConfigured = true
    }

    /// Angle de rotation (degrés) d'une connexion de la caméra arrière pour une orientation
    /// d'interface : capteur nativement en paysage « bouton à droite ».
    static func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        default: 90
        }
    }
}

extension CardScanCamera: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        let result: Result<CapturedPhoto, any Error>
        if error == nil, let image = photo.cgImageRepresentation() {
            let rawOrientation = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32
            let orientation = rawOrientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .right
            result = .success(CapturedPhoto(image: image, orientation: orientation))
        } else {
            result = .failure(Failure.captureFailed)
        }
        queue.async {
            self.pendingCapture?.resume(with: result)
            self.pendingCapture = nil
        }
    }
}

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
