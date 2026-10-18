import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Zone du cadre-guide à l'écran au moment de la photo (pour ignorer ce qui est hors cadre).
struct CardScanRegion: Sendable, Equatable {
    let guide: CGRect
    let viewSize: CGSize
}

/// Le bouton « Scanner les cartes » n'est proposé que si un appareil photo arrière existe
/// (jamais sur simulateur), ou, en Debug, si un résultat simulé est demandé (`-scanFixture`).
enum CardScanAvailability {
    static let isOffered: Bool = {
        #if DEBUG
        if CardScanFixture.current != nil { return true }
        #endif
        return CardScanCamera.isHardwareAvailable
    }()
}

/// Déroulement d'un scan (prototype P2) : autorisation → aperçu → photo → lecture → vérification.
///
/// - Autorisation demandée **au premier usage seulement** (statut `notDetermined`) ; refus ou
///   restriction : message, saisie manuelle intacte, aucune nouvelle demande.
/// - La photo n'existe que dans `read(_:)` (jamais stockée dans le modèle) ; la session est
///   arrêtée dès la photo prise.
/// - Aucun effet sur la manche : le résultat est seulement proposé à l'écran de vérification.
@MainActor
@Observable
final class CardScanModel {
    enum Phase: Equatable {
        case preparing
        case denied
        case restricted
        case unavailable
        case capturing
        case analyzing
        case review(CardScanResult)
        case failed
    }

    private(set) var phase: Phase = .preparing
    /// Incrémenté à chaque résultat affiché (retour haptique léger).
    private(set) var resultCount = 0

    /// `nil` : pas d'appareil photo (ou résultat simulé).
    let camera: CardScanCamera?
    private let fixtureObservations: [CardScanObservation]?

    init(camera: CardScanCamera?, fixtureObservations: [CardScanObservation]? = nil) {
        self.camera = camera
        self.fixtureObservations = fixtureObservations
    }

    /// Appareil photo réel, ou résultat simulé en Debug (`-uiTesting -scanFixture <nom>`).
    static func makeDefault() -> CardScanModel {
        #if DEBUG
        if let fixture = CardScanFixture.current {
            return CardScanModel(camera: nil, fixtureObservations: fixture.observations)
        }
        #endif
        return CardScanModel(camera: CardScanCamera.isHardwareAvailable ? CardScanCamera() : nil)
    }

    /// Démarre (ou redémarre après « Reprendre la photo ») ; sans effet hors de `.preparing`.
    func start() async {
        guard phase == .preparing else { return }
        if let fixtureObservations {
            show(CardGridRecognizer.recognize(fixtureObservations))
            return
        }
        guard let camera else {
            phase = .unavailable
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            // Premier usage : seule demande d'autorisation de l'app.
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                phase = .denied
                return
            }
        case .restricted:
            phase = .restricted
            return
        case .denied:
            phase = .denied
            return
        @unknown default:
            phase = .denied
            return
        }
        do {
            try await camera.start()
            if phase == .preparing {
                phase = .capturing
            }
        } catch {
            phase = .unavailable
        }
    }

    /// Prend la photo, l'analyse sur l'appareil puis affiche la grille proposée.
    func capture(region: CardScanRegion?) async {
        guard phase == .capturing, let camera else { return }
        phase = .analyzing
        do {
            let output = try await Self.read(camera)
            camera.stop()
            let regionOfInterest = region.flatMap {
                CardScanGeometry.regionOfInterest(
                    guide: $0.guide,
                    viewSize: $0.viewSize,
                    imageAspectRatio: output.imageAspectRatio
                )
            }
            show(CardGridRecognizer.recognize(
                output.observations,
                imageAspectRatio: output.imageAspectRatio,
                regionOfInterest: regionOfInterest
            ))
        } catch {
            camera.stop()
            if phase == .analyzing {
                phase = .failed
            }
        }
    }

    /// « Reprendre la photo » : nouvel aperçu (autorisation déjà accordée).
    func retake() async {
        phase = .preparing
        await start()
    }

    /// Fermeture de l'écran : session arrêtée, prise de vue éventuelle abandonnée.
    func stop() {
        camera?.stop()
    }

    private func show(_ result: CardScanResult) {
        phase = .review(result)
        resultCount += 1
    }

    /// Photo prise et lue hors du main actor ; elle est libérée à la sortie de cette fonction.
    private nonisolated static func read(_ camera: CardScanCamera) async throws -> CardScanTextReader.Output {
        let photo = try await camera.capturePhoto()
        return try await CardScanTextReader.read(photo)
    }
}
