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
/// donnée ne quitte l'iPhone. L'analyse est limitée au cadre-guide (`regionOfInterest`, avec une
/// marge) ; le résultat est converti en `CardScanObservation` dans l'image entière (logique pure
/// testée sans Vision).
enum CardScanTextReader {
    struct Output: Sendable, Equatable {
        let observations: [CardScanObservation]
        /// Largeur / hauteur de l'image redressée.
        let imageAspectRatio: Double
        /// Cadre-guide dans l'image redressée (origine en haut à gauche) ; `nil` si inconnu.
        let regionOfInterest: NormalizedBox?
    }

    /// Analyse la photo dans une tâche détachée (jamais sur le main actor). La photo n'est
    /// retenue que pendant cet appel.
    static func read(_ photo: CapturedPhoto, region: CardScanRegion?) async throws -> Output {
        try await Task.detached(priority: .userInitiated) {
            try Self.recognize(photo, region: region)
        }.value
    }

    private static func recognize(_ photo: CapturedPhoto, region: CardScanRegion?) throws -> Output {
        try Task.checkCancellation()
        let aspect = photo.uprightAspectRatio
        let regionOfInterest = region.flatMap {
            CardScanGeometry.regionOfInterest(guide: $0.guide, viewSize: $0.viewSize, imageAspectRatio: aspect)
        }
        let visionRegion = regionOfInterest.map {
            CardScanGeometry.visionRegion(for: $0, margin: CardGridRecognizer.Tuning.regionMargin)
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Chiffres isolés : la correction linguistique les transformerait en mots.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["fr-FR", "en-US"]
        if let visionRegion, visionRegion.width > 0, visionRegion.height > 0 {
            request.regionOfInterest = visionRegion
        }
        let handler = VNImageRequestHandler(cgImage: photo.image, orientation: photo.orientation, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()
        var observations: [CardScanObservation] = []
        for result in request.results ?? [] {
            observations += convert(result, visionRegion: request.regionOfInterest)
        }
        return Output(observations: observations, imageAspectRatio: aspect, regionOfInterest: regionOfInterest)
    }

    /// Une ligne contenant plusieurs nombres (« 5 7 ») est découpée en mots, chacun avec sa boîte
    /// et ses lectures candidates (les 3 meilleures, mot par mot). Les boîtes Vision, relatives à
    /// la zone analysée, sont ramenées à l'image entière.
    private static func convert(
        _ observation: VNRecognizedTextObservation,
        visionRegion: CGRect?
    ) -> [CardScanObservation] {
        let recognized = observation.topCandidates(3)
        guard let best = recognized.first else { return [] }
        let candidates = recognized.map {
            CardScanObservation.Candidate(text: $0.string, confidence: Double($0.confidence))
        }
        let words = CardGridRecognizer.tokenRanges(in: best.string)
        guard words.count > 1 else {
            return [CardScanObservation(
                candidates: candidates,
                box: NormalizedBox(visionRect: observation.boundingBox, within: visionRegion)
            )]
        }
        let perWord = CardGridRecognizer.wordCandidates(candidates)
        return zip(words, perWord).compactMap { range, wordCandidates -> CardScanObservation? in
            guard let wordBox = try? best.boundingBox(for: range)?.boundingBox else { return nil }
            return CardScanObservation(
                candidates: wordCandidates,
                box: NormalizedBox(visionRect: wordBox, within: visionRegion)
            )
        }
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

    /// Boîte Vision relative à la zone analysée `region` (coordonnées Vision de l'image entière),
    /// ramenée à l'image entière puis à l'origine en haut à gauche. `nil` : image entière.
    init(visionRect rect: CGRect, within region: CGRect?) {
        guard let region else {
            self.init(visionRect: rect)
            return
        }
        self.init(visionRect: CGRect(
            x: region.minX + rect.minX * region.width,
            y: region.minY + rect.minY * region.height,
            width: rect.width * region.width,
            height: rect.height * region.height
        ))
    }
}
