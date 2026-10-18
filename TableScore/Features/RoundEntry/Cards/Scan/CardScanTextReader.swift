import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Photo capturée, gardée **uniquement en mémoire** le temps de l'analyse (prototype P2).
///
/// Jamais écrite sur disque ni dans la photothèque : aucune API d'enregistrement n'est appelée,
/// et la valeur est libérée dès la fin de `CardScanTextReader.read`. `CGImage` est immuable :
/// le partage entre tâches est sûr.
struct CapturedPhoto: @unchecked Sendable {
    let image: CGImage
    /// Orientation EXIF à appliquer pour redresser l'image.
    let orientation: CGImagePropertyOrientation

    /// Largeur / hauteur de l'image **redressée**.
    var uprightAspectRatio: Double {
        let width = Double(image.width)
        let height = Double(image.height)
        guard width > 0, height > 0 else { return CardGridRecognizer.Tuning.defaultImageAspectRatio }
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return height / width
        default:
            return width / height
        }
    }
}

/// Adaptateur Vision : reconnaissance de texte **sur l'appareil**, hors du main actor.
///
/// `VNRecognizeTextRequest` s'exécute localement (Vision ne propose pas de mode serveur) ; aucune
/// donnée ne quitte l'iPhone. Le résultat est converti en `CardScanObservation` (logique pure
/// testée sans Vision).
enum CardScanTextReader {
    struct Output: Sendable {
        let observations: [CardScanObservation]
        /// Largeur / hauteur de l'image redressée.
        let imageAspectRatio: Double
    }

    /// Analyse la photo dans une tâche détachée (jamais sur le main actor). La photo n'est
    /// retenue que pendant cet appel.
    static func read(_ photo: CapturedPhoto) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            try Self.recognize(photo)
        }.value
    }

    private static func recognize(_ photo: CapturedPhoto) throws -> Output {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Chiffres isolés : la correction linguistique les transformerait en mots.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["fr-FR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: photo.image, orientation: photo.orientation, options: [:])
        try handler.perform([request])
        let results = request.results ?? []
        var observations: [CardScanObservation] = []
        for result in results {
            observations += convert(result)
        }
        return Output(observations: observations, imageAspectRatio: photo.uprightAspectRatio)
    }

    /// Une ligne contenant plusieurs nombres (« 5 7 ») est découpée en mots, chacun avec sa boîte.
    private static func convert(_ observation: VNRecognizedTextObservation) -> [CardScanObservation] {
        let candidates = observation.topCandidates(3)
        guard let best = candidates.first else { return [] }
        let words = CardGridRecognizer.tokenRanges(in: best.string)
        if words.count > 1 {
            return words.compactMap { range -> CardScanObservation? in
                guard let wordBox = try? best.boundingBox(for: range)?.boundingBox else { return nil }
                return CardScanObservation(
                    candidates: [.init(text: String(best.string[range]), confidence: Double(best.confidence))],
                    box: NormalizedBox(visionRect: wordBox)
                )
            }
        }
        return [CardScanObservation(
            candidates: candidates.map { .init(text: $0.string, confidence: Double($0.confidence)) },
            box: NormalizedBox(visionRect: observation.boundingBox)
        )]
    }
}

extension NormalizedBox {
    /// Conversion depuis Vision (origine en bas à gauche) vers l'origine en haut à gauche.
    init(visionRect rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(1 - rect.origin.y - rect.height),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }
}
