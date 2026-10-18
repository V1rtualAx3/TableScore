import AVFoundation
import CoreGraphics
import Foundation
import Observation

/// Zone du cadre-guide à l'écran au moment de la photo (pour ignorer ce qui est hors cadre).
struct CardScanRegion: Sendable, Equatable {
    let guide: CGRect
    let viewSize: CGSize
}

/// Résultat de la demande d'accès à l'appareil photo.
enum CardScanAccess: Sendable, Equatable {
    case granted
    case denied
    case restricted
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

/// Déroulement d'un scan (prototype P2) : autorisation → aperçu → photo → **caméra coupée** →
/// lecture → vérification.
///
/// - Autorisation demandée **au premier usage seulement** (statut `notDetermined`) ; refus ou
///   restriction : message, saisie manuelle intacte, aucune nouvelle demande.
/// - La photo n'existe que dans `captureThenRead` (jamais stockée dans le modèle) ; la session est
///   arrêtée **avant** l'analyse.
/// - Interruption de la caméra (appel, autre app) : message, reprise automatique à la fin.
/// - Aucun effet sur la manche : le résultat est seulement proposé à l'écran de vérification.
@MainActor
@Observable
final class CardScanModel {
    typealias AccessRequest = @Sendable () async -> CardScanAccess
    typealias Reader = @Sendable (CapturedPhoto, CardScanRegion?) async throws -> CardScanTextReader.Output

    enum Phase: Equatable {
        case preparing
        case denied
        case restricted
        case unavailable
        case capturing
        case interrupted
        case analyzing
        case review(CardScanResult)
        case failed
    }

    private(set) var phase: Phase = .preparing
    /// Incrémenté à chaque résultat affiché (retour haptique léger, identité de la vérification).
    private(set) var resultCount = 0

    /// `nil` : pas d'appareil photo (ou résultat simulé).
    let camera: (any CardScanCapturing)?
    private let access: AccessRequest
    private let reader: Reader
    private let fixtureOutput: CardScanTextReader.Output?

    init(
        camera: (any CardScanCapturing)?,
        access: @escaping AccessRequest = { await CardScanModel.systemAccess() },
        reader: @escaping Reader = { photo, region in try await CardScanTextReader.read(photo, region: region) },
        fixtureOutput: CardScanTextReader.Output? = nil
    ) {
        self.camera = camera
        self.access = access
        self.reader = reader
        self.fixtureOutput = fixtureOutput
        let relay = InterruptionRelay(model: self)
        camera?.setInterruptionHandler { isInterrupted in
            Task { @MainActor in
                relay.model?.interruptionChanged(isInterrupted)
            }
        }
    }

    /// Appareil photo réel, ou résultat simulé en Debug (`-uiTesting -scanFixture <nom>`).
    static func makeDefault() -> CardScanModel {
        #if DEBUG
        if let fixture = CardScanFixture.current {
            return CardScanModel(camera: nil, fixtureOutput: fixture.output)
        }
        #endif
        return CardScanModel(camera: CardScanCamera.isHardwareAvailable ? CardScanCamera() : nil)
    }

    /// Autorisation système ; la demande n'est affichée que si le statut est `notDetermined`.
    nonisolated static func systemAccess() async -> CardScanAccess {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .granted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        @unknown default:
            return .denied
        }
    }

    /// Démarre (ou redémarre après « Reprendre la photo ») ; sans effet hors de `.preparing`.
    func start() async {
        guard phase == .preparing else { return }
        if let fixtureOutput {
            show(Self.recognize(fixtureOutput))
            return
        }
        guard let camera else {
            phase = .unavailable
            return
        }
        switch await access() {
        case .granted:
            break
        case .denied:
            phase = .denied
            return
        case .restricted:
            phase = .restricted
            return
        }
        do {
            try await camera.start()
            if phase == .preparing {
                phase = .capturing
            }
        } catch {
            if phase == .preparing {
                phase = .unavailable
            }
        }
    }

    /// Prend la photo, coupe la caméra, analyse sur l'appareil puis affiche la grille proposée.
    func capture(region: CardScanRegion?) async {
        guard phase == .capturing, let camera else { return }
        phase = .analyzing
        do {
            let output = try await Self.captureThenRead(camera: camera, reader: reader, region: region)
            guard phase == .analyzing, !Task.isCancelled else { return }
            show(Self.recognize(output))
        } catch {
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

    /// Interruption de la session (appel, autre app) pendant l'aperçu, puis reprise.
    func interruptionChanged(_ isInterrupted: Bool) {
        if isInterrupted, phase == .capturing {
            phase = .interrupted
        } else if !isInterrupted, phase == .interrupted {
            phase = .capturing
        }
    }

    private func show(_ result: CardScanResult) {
        phase = .review(result)
        resultCount += 1
    }

    private static func recognize(_ output: CardScanTextReader.Output) -> CardScanResult {
        CardGridRecognizer.recognize(
            output.observations,
            imageAspectRatio: output.imageAspectRatio,
            regionOfInterest: output.regionOfInterest
        )
    }

    /// Ordre garanti : photo → caméra coupée → lecture (hors du main actor). La photo est libérée
    /// à la sortie de cette fonction.
    private nonisolated static func captureThenRead(
        camera: any CardScanCapturing,
        reader: Reader,
        region: CardScanRegion?
    ) async throws -> CardScanTextReader.Output {
        let photo: CapturedPhoto
        do {
            photo = try await camera.capturePhoto()
        } catch {
            camera.stop()
            throw error
        }
        camera.stop()
        try Task.checkCancellation()
        return try await reader(photo, region)
    }
}

/// Relais faible vers le modèle pour les notifications d'interruption (évite un cycle
/// caméra → gestionnaire → modèle). Écrit à l'initialisation, lu sur le main actor uniquement.
private final class InterruptionRelay: @unchecked Sendable {
    weak var model: CardScanModel?

    init(model: CardScanModel) {
        self.model = model
    }
}
