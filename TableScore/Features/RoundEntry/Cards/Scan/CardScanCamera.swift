import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UIKit

/// Prise de vue utilisée par `CardScanModel` (injectable : tests sans caméra).
protocol CardScanCapturing: AnyObject, Sendable {
    /// Configure si besoin puis démarre l'aperçu.
    func start() async throws
    /// Prend une photo, gardée en mémoire uniquement.
    func capturePhoto() async throws -> CapturedPhoto
    /// Arrête la session (voyant éteint) et abandonne une prise de vue en cours.
    func stop()
    /// `true` : session interrompue (appel, autre app…) ; `false` : interruption terminée.
    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?)
}

/// Appareil photo arrière pour le prototype P2 « Scanner les cartes ».
///
/// - Session `AVCaptureSession` + sortie photo **en mémoire** : aucune vidéo, aucun son, aucun
///   fichier, aucune photothèque ; taille de photo limitée (≤ 4032 px si possible).
/// - `@unchecked Sendable` : l'état mutable (`isConfigured`, `captureRotationAngle`,
///   `pendingCapture`, `pendingCaptureID`) n'est lu et écrit **que sur `queue`** (file série) ;
///   `interruptionHandler` est protégé par `handlerLock` ; `session`, `output` et `queue` sont des
///   constantes. Seule exception, conforme aux exemples d'Apple : l'aperçu reçoit `session` sur
///   le main thread (`AVCaptureVideoPreviewLayer.session`).
/// - L'autorisation est demandée par `CardScanModel`, au premier usage seulement.
final class CardScanCamera: NSObject, @unchecked Sendable, CardScanCapturing {
    enum Failure: Error, Equatable {
        case unavailable
        case configurationFailed
        case captureFailed
        case cancelled
    }

    /// Plus grand côté souhaité pour la photo (lecture de chiffres : inutile d'aller au-delà).
    static let maximumPhotoSide = 4032

    /// Session partagée avec l'aperçu (`AVCaptureVideoPreviewLayer`).
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "app.tablescore.cardscan.camera")

    // État confiné à `queue`.
    private var isConfigured = false
    private var captureRotationAngle: CGFloat = 90
    private var pendingCapture: CheckedContinuation<CapturedPhoto, any Error>?
    /// `uniqueID` des réglages de la prise en cours : un rappel tardif d'une prise abandonnée
    /// est ignoré.
    private var pendingCaptureID: Int64?

    private let handlerLock = NSLock()
    private var interruptionHandler: (@Sendable (Bool) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        let interrupted = center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.notifyInterruption(true)
        }
        let ended = center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.notifyInterruption(false)
        }
        observers = [interrupted, ended]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Appareil photo arrière présent (faux sur simulateur).
    static var isHardwareAvailable: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
        #endif
    }

    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {
        handlerLock.withLock { interruptionHandler = handler }
    }

    private func notifyInterruption(_ isInterrupted: Bool) {
        let handler = handlerLock.withLock { interruptionHandler }
        handler?(isInterrupted)
    }

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

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.pendingCapture?.resume(throwing: Failure.cancelled)
            self.pendingCapture = nil
            self.pendingCaptureID = nil
        }
    }

    /// Angle de rotation à appliquer à la photo (suivi de l'orientation de l'interface).
    func setCaptureRotationAngle(_ angle: CGFloat) {
        queue.async {
            self.captureRotationAngle = angle
        }
    }

    func capturePhoto() async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedPhoto, any Error>) in
            queue.async {
                guard self.session.isRunning, !self.session.isInterrupted, self.pendingCapture == nil else {
                    continuation.resume(throwing: Failure.captureFailed)
                    return
                }
                if let connection = self.output.connection(with: .video),
                   connection.isVideoRotationAngleSupported(self.captureRotationAngle) {
                    connection.videoRotationAngle = self.captureRotationAngle
                }
                let settings = AVCapturePhotoSettings()
                settings.photoQualityPrioritization = .balanced
                settings.maxPhotoDimensions = self.output.maxPhotoDimensions
                self.pendingCapture = continuation
                self.pendingCaptureID = settings.uniqueID
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
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw Failure.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.maxPhotoQualityPrioritization = .balanced
        // Après validation de la configuration : format actif définitif (une taille non proposée
        // par ce format serait refusée).
        let supported = device.activeFormat.supportedMaxPhotoDimensions
        let sizes = supported.map { (width: Int($0.width), height: Int($0.height)) }
        if let index = Self.preferredPhotoDimensionsIndex(sizes, maximumSide: Self.maximumPhotoSide) {
            output.maxPhotoDimensions = supported[index]
        }
        isConfigured = true
    }

    /// Taille de photo retenue (pure) : la plus grande dont le plus grand côté ≤ `maximumSide`,
    /// sinon la plus petite proposée ; `nil` si aucune.
    static func preferredPhotoDimensionsIndex(_ sizes: [(width: Int, height: Int)], maximumSide: Int) -> Int? {
        func area(_ index: Int) -> Int { sizes[index].width * sizes[index].height }
        let fitting = sizes.indices.filter { max(sizes[$0].width, sizes[$0].height) <= maximumSide }
        if let largest = fitting.max(by: { area($0) < area($1) }) {
            return largest
        }
        return sizes.indices.min(by: { area($0) < area($1) })
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
        let captureID = photo.resolvedSettings.uniqueID
        let result: Result<CapturedPhoto, any Error>
        if error == nil, let image = photo.cgImageRepresentation() {
            let rawOrientation = photo.metadata[kCGImagePropertyOrientation as String] as? UInt32
            let orientation = rawOrientation.flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .right
            result = .success(CapturedPhoto(image: image, orientation: orientation))
        } else {
            result = .failure(Failure.captureFailed)
        }
        queue.async {
            // Rappel d'une prise abandonnée (`stop`) ou inattendue : ignoré.
            guard captureID == self.pendingCaptureID else { return }
            self.pendingCapture?.resume(with: result)
            self.pendingCapture = nil
            self.pendingCaptureID = nil
        }
    }
}
