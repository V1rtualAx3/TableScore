import Foundation
import TableScoreKit

// Prototype P2 « Scanner les cartes d'un joueur » (décision utilisateur du 2026-10-18, cahier §2).
//
// Logique **pure et déterministe** : aucune dépendance à Vision, à l'appareil photo ni à SwiftUI.
// Elle reçoit des observations de texte déjà extraites (texte, confiance, boîte) et propose une
// grille 3 × 4 **à vérifier** : aucune valeur n'est enregistrée sans l'action « Enregistrer la
// manche » habituelle, et aucune colonne n'est jamais marquée retirée automatiquement.

/// Rectangle normalisé (0…1) dans l'image **redressée** : origine en haut à gauche, y vers le bas.
/// (L'adaptateur Vision convertit depuis l'origine en bas à gauche de Vision.)
struct NormalizedBox: Sendable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var midX: Double { x + width / 2 }
    var midY: Double { y + height / 2 }

    /// Géométrie exploitable : valeurs finies, taille strictement positive et plausible.
    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && width > 0 && height > 0 && width <= 1.5 && height <= 1.5
    }

    /// Le point (normalisé) est dans le rectangle élargi de `margin` de chaque côté.
    func contains(x pointX: Double, y pointY: Double, margin: Double) -> Bool {
        pointX >= x - margin && pointX <= x + width + margin
            && pointY >= y - margin && pointY <= y + height + margin
    }
}

/// Texte reconnu (une ligne ou un mot), avec ses lectures candidates, la meilleure en premier.
struct CardScanObservation: Sendable, Equatable {
    struct Candidate: Sendable, Equatable {
        let text: String
        /// 0…1 (bornée à la lecture).
        let confidence: Double
    }

    let candidates: [Candidate]
    let box: NormalizedBox
}

/// Grille proposée après lecture d'une photo. Les cases incertaines restent **vides** (jamais
/// de valeur devinée dans la grille) ; la lecture probable est seulement suggérée en texte.
struct CardScanResult: Sendable, Equatable {
    typealias Cell = CardGridPresentation.CellPosition

    /// Valeurs lues avec assurance ; aucune colonne marquée retirée.
    let grid: CardGrid
    /// Cases à confirmer par l'utilisateur, colonne par colonne (haut → bas).
    let uncertainCells: [Cell]
    /// Lecture probable d'une case incertaine (« 6 ? »), à confirmer.
    let suggestions: [Cell: Int]
    /// Colonnes sans aucune carte lue (peut-être retirées pendant la manche : à marquer par
    /// l'utilisateur, jamais automatiquement).
    let emptyColumns: [Int]

    static let empty = CardScanResult(
        grid: CardGrid(),
        uncertainCells: [],
        suggestions: [:],
        emptyColumns: Array(0..<CardGrid.columnCount)
    )

    static var cardCount: Int { CardGrid.columnCount * CardGrid.rowCount }

    /// Cartes lues avec assurance (pré-remplies).
    var recognizedCount: Int {
        grid.columns.reduce(0) { $0 + $1.values.compactMap { $0 }.count }
    }

    /// Cartes repérées sur la photo (assurées + à vérifier).
    var detectedCount: Int { recognizedCount + uncertainCells.count }
}

/// Reconnaissance de la grille d'un joueur à partir des observations de texte (pure).
///
/// Étapes : lecture des valeurs −2…12 (signes « - », « − », « – », « — »…) → filtrage par la
/// zone du cadre-guide → fusion des doublons superposés → séparation des grands chiffres
/// (centre des cartes) et des petits (indices de coin) → correction d'une rotation légère →
/// regroupement 1D en 4 colonnes puis 3 rangées → contrôle de cohérence (doublons, indices
/// de coin, lectures concurrentes, confiance).
///
/// Une case est **incertaine** (laissée vide, à confirmer) si : confiance < seuil, autre lecture
/// candidate proche (ex. « 6 »/« 9 »), lectures contradictoires sur la même carte, ou signe
/// moins détaché du chiffre. Les seuils (`Tuning`) sont des valeurs de départ, **à calibrer
/// sur de vraies cartes**.
enum CardGridRecognizer {
    enum Tuning {
        /// En dessous : case incertaine (Vision donne souvent 0,3 / 0,5 / 1).
        static let minimumConfidence = 0.5
        /// Autre lecture candidate valide dont la confiance est à moins de cet écart : ambiguïté.
        static let ambiguityMargin = 0.15
        /// Deux lectures se recouvrant à ce point (intersection / plus petite aire) : doublon.
        static let overlapRatio = 0.6
        /// Hauteur minimale d'un « grand chiffre », relative à la 3ᵉ plus grande hauteur.
        static let primaryHeightRatio = 0.5
        /// Tolérance autour du cadre-guide (fraction de l'image).
        static let regionMargin = 0.05
        /// Écart (en hauteurs de chiffre) au-delà duquel on change de colonne ou de rangée.
        static let splitGapRatio = 0.8
        /// Rotation maximale corrigée, en degrés.
        static let maximumSkewDegrees = 20.0
        /// Un grand chiffre sans voisin à moins de N hauteurs est ignoré (bruit isolé).
        static let isolationRatio = 4.0
        /// Rayon (en hauteurs de chiffre) de rattachement d'un indice de coin à sa carte.
        static let secondaryRadiusRatio = 2.5
        /// Écart maximal (en hauteurs) entre un signe moins détaché et son chiffre.
        static let detachedSignGapRatio = 1.0
        /// Rapport largeur / hauteur d'une photo portrait 4:3 (valeur par défaut).
        static let defaultImageAspectRatio = 0.75
    }

    // MARK: Lecture d'un texte

    /// Signes « moins » acceptés (trait d'union, signe moins, tirets demi-cadratin et cadratin…).
    static let minusSigns: Set<Character> = [
        "-", "\u{2212}", "\u{2013}", "\u{2014}", "\u{2010}", "\u{2011}", "\u{2012}", "\u{FE63}", "\u{FF0D}"
    ]

    /// Caractères parasites ignorés autour d'un nombre (espaces, point, soulignement…).
    private static let ignoredCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "._,\u{00B7}'\u{2018}\u{2019}\""))

    /// Valeur de carte lue dans un texte (« 7 », « -2 », « − 1 », « 12 ») ; `nil` si le texte
    /// n'est pas exactement une valeur −2…12 (« 13 », « 05 », « -0 », lettres, plusieurs nombres).
    static func parseCardValue(_ text: String) -> Int? {
        var body = text.trimmingCharacters(in: ignoredCharacters)
        var isNegative = false
        if let first = body.first, minusSigns.contains(first) {
            isNegative = true
            body = String(body.dropFirst()).trimmingCharacters(in: ignoredCharacters)
        }
        guard (1...2).contains(body.count),
              body.allSatisfy({ $0.isASCII && $0.isWholeNumber }),
              !(body.count == 2 && body.first == "0"),
              let magnitude = Int(body)
        else { return nil }
        if isNegative && magnitude == 0 { return nil }
        let value = isNegative ? -magnitude : magnitude
        return CardGrid.cardValues.contains(value) ? value : nil
    }

    /// Texte composé uniquement de signes moins (signe lu séparément de son chiffre).
    static func isSignOnly(_ text: String) -> Bool {
        let body = text.trimmingCharacters(in: ignoredCharacters)
        return !body.isEmpty && body.allSatisfy { minusSigns.contains($0) }
    }

    /// Découpe une ligne reconnue en mots (séparés par des espaces), un signe isolé étant
    /// rattaché au mot suivant (« - 2 » reste un seul mot). Utilisé par l'adaptateur Vision
    /// quand plusieurs cartes d'une rangée sont lues sur une même ligne.
    static func tokenRanges(in text: String) -> [Range<String.Index>] {
        var words: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let isSpace = text[index].isWhitespace
            if isSpace, let wordStart = start {
                words.append(wordStart..<index)
                start = nil
            } else if !isSpace, start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let wordStart = start {
            words.append(wordStart..<text.endIndex)
        }
        var merged: [Range<String.Index>] = []
        var pendingSign: Range<String.Index>?
        for word in words {
            if let sign = pendingSign {
                merged.append(sign.lowerBound..<word.upperBound)
                pendingSign = nil
            } else if isSignOnly(String(text[word])) {
                pendingSign = word
            } else {
                merged.append(word)
            }
        }
        if let sign = pendingSign {
            merged.append(sign)
        }
        return merged
    }

    // MARK: Reconnaissance

    /// Point exprimé en **hauteurs d'image** (x multiplié par le rapport largeur / hauteur) :
    /// les distances et les rotations sont ainsi isotropes.
    private struct Point {
        var x: Double
        var y: Double

        func distance(to other: Point) -> Double {
            hypot(x - other.x, y - other.y)
        }
    }

    private struct Reading {
        var value: Int
        let confidence: Double
        /// Autre lecture candidate proche, ou meilleure lecture non retenue (texte invalide).
        let isAmbiguous: Bool
        let center: Point
        let width: Double
        let height: Double
        /// Lectures contradictoires (doublon superposé, signe détaché…).
        var hasConflict = false

        func overlapRatio(with other: Reading) -> Double {
            let overlapWidth = min(center.x + width / 2, other.center.x + other.width / 2)
                - max(center.x - width / 2, other.center.x - other.width / 2)
            let overlapHeight = min(center.y + height / 2, other.center.y + other.height / 2)
                - max(center.y - height / 2, other.center.y - other.height / 2)
            guard overlapWidth > 0, overlapHeight > 0 else { return 0 }
            let smallerArea = min(width * height, other.width * other.height)
            return smallerArea > 0 ? overlapWidth * overlapHeight / smallerArea : 0
        }
    }

    private struct CellReading {
        let reading: Reading
        let point: Point
        var isUncertain: Bool
    }

    /// Propose la grille d'un joueur.
    /// - Parameters:
    ///   - imageAspectRatio: largeur / hauteur de l'image redressée (0,75 en portrait 4:3).
    ///   - regionOfInterest: zone du cadre-guide dans l'image (normalisée) ; les textes dont le
    ///     centre est en dehors (cartes d'un voisin, feuille de score…) sont ignorés.
    static func recognize(
        _ observations: [CardScanObservation],
        imageAspectRatio: Double = Tuning.defaultImageAspectRatio,
        regionOfInterest: NormalizedBox? = nil
    ) -> CardScanResult {
        let aspect = imageAspectRatio.isFinite && imageAspectRatio > 0
            ? imageAspectRatio : Tuning.defaultImageAspectRatio
        var readings = parseReadings(observations, aspect: aspect)
        if let region = regionOfInterest, region.isValid {
            readings = readings.filter {
                region.contains(x: $0.center.x / aspect, y: $0.center.y, margin: Tuning.regionMargin)
            }
        }
        let distinct = removeOverlaps(readings)
        guard !distinct.isEmpty else { return .empty }

        let heights = distinct.map(\.height).sorted(by: >)
        let reference = heights[min(2, heights.count - 1)]
        var primary = distinct.filter { $0.height >= Tuning.primaryHeightRatio * reference }
        let secondary = distinct.filter { $0.height < Tuning.primaryHeightRatio * reference }
        primary.sort { ($0.center.y, $0.center.x) < ($1.center.y, $1.center.x) }
        primary = removeIsolated(primary)
        guard !primary.isEmpty else { return .empty }

        let digitHeight = median(primary.map(\.height))
        let skew = estimateSkewDegrees(primary.map(\.center))
        let pivot = Point(
            x: primary.map(\.center.x).reduce(0, +) / Double(primary.count),
            y: primary.map(\.center.y).reduce(0, +) / Double(primary.count)
        )
        let points = primary.map { rotate($0.center, around: pivot, degrees: -skew) }

        let threshold = Tuning.splitGapRatio * digitHeight
        let columns = clusters(of: points.map(\.x), maxClusters: CardGrid.columnCount, threshold: threshold)
        let rows = clusters(of: points.map(\.y), maxClusters: CardGrid.rowCount, threshold: threshold)
        let columnSlots = slots(forCenters: columns.centers, slotCount: CardGrid.columnCount)
        let rowSlots = slots(forCenters: rows.centers, slotCount: CardGrid.rowCount)

        var candidatesByCell: [CardScanResult.Cell: [(reading: Reading, point: Point)]] = [:]
        for (index, reading) in primary.enumerated() {
            let cell = CardScanResult.Cell(column: columnSlots[columns.ids[index]], row: rowSlots[rows.ids[index]])
            candidatesByCell[cell, default: []].append((reading, points[index]))
        }

        var cells: [CardScanResult.Cell: CellReading] = [:]
        for (cell, candidates) in candidatesByCell {
            let ordered = candidates.sorted { lhs, rhs in
                if lhs.reading.confidence != rhs.reading.confidence {
                    return lhs.reading.confidence > rhs.reading.confidence
                }
                if lhs.reading.height != rhs.reading.height { return lhs.reading.height > rhs.reading.height }
                return (lhs.point.x, lhs.point.y) < (rhs.point.x, rhs.point.y)
            }
            guard let best = ordered.first else { continue }
            let hasConflict = best.reading.hasConflict
                || ordered.dropFirst().contains { $0.reading.value != best.reading.value }
            cells[cell] = CellReading(
                reading: best.reading,
                point: best.point,
                isUncertain: hasConflict || best.reading.isAmbiguous
                    || best.reading.confidence < Tuning.minimumConfidence
            )
        }

        checkSecondaryReadings(secondary, against: &cells, pivot: pivot, skew: skew)
        return makeResult(cells)
    }

    // MARK: Étapes

    private static func parseReadings(_ observations: [CardScanObservation], aspect: Double) -> [Reading] {
        var signs: [NormalizedBox] = []
        var readings: [Reading] = []
        for observation in observations where observation.box.isValid {
            guard let top = observation.candidates.first else { continue }
            if isSignOnly(top.text) {
                signs.append(observation.box)
                continue
            }
            var parsed: [(value: Int, confidence: Double, rank: Int)] = []
            for (rank, candidate) in observation.candidates.enumerated() {
                guard let value = parseCardValue(candidate.text) else { continue }
                let confidence = candidate.confidence.isFinite ? min(max(candidate.confidence, 0), 1) : 0
                parsed.append((value, confidence, rank))
            }
            guard let best = parsed.first else { continue }
            let hasCloseAlternative = parsed.dropFirst().contains {
                $0.value != best.value && $0.confidence >= best.confidence - Tuning.ambiguityMargin
            }
            let box = observation.box
            readings.append(Reading(
                value: best.value,
                confidence: best.confidence,
                isAmbiguous: hasCloseAlternative || best.rank != 0,
                center: Point(x: box.midX * aspect, y: box.midY),
                width: box.width * aspect,
                height: box.height
            ))
        }
        attachDetachedSigns(signs, to: &readings, aspect: aspect)
        return readings
    }

    /// Un signe moins lu à part, juste à gauche d'un chiffre positif sur la même ligne, en fait
    /// une valeur négative **à confirmer** (jamais de signe deviné en silence).
    private static func attachDetachedSigns(_ signs: [NormalizedBox], to readings: inout [Reading], aspect: Double) {
        for sign in signs {
            let signRight = (sign.x + sign.width) * aspect
            var best: (gap: Double, index: Int)?
            for (index, reading) in readings.enumerated() where reading.value > 0 {
                let gap = reading.center.x - reading.width / 2 - signRight
                let isOnSameLine = abs(reading.center.y - sign.midY) <= 0.5 * reading.height
                let isAdjacent = gap >= -0.25 * reading.height && gap <= Tuning.detachedSignGapRatio * reading.height
                if isOnSameLine, isAdjacent, best.map({ gap < $0.gap }) ?? true {
                    best = (gap, index)
                }
            }
            guard let index = best?.index else { continue }
            if CardGrid.cardValues.contains(-readings[index].value) {
                readings[index].value = -readings[index].value
            }
            readings[index].hasConflict = true
        }
    }

    /// Lectures superposées : on garde la plus sûre ; des valeurs différentes rendent la case
    /// incertaine.
    private static func removeOverlaps(_ readings: [Reading]) -> [Reading] {
        let ordered = readings.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            return (lhs.center.x, lhs.center.y) < (rhs.center.x, rhs.center.y)
        }
        var kept: [Reading] = []
        for reading in ordered {
            if let index = kept.firstIndex(where: { $0.overlapRatio(with: reading) >= Tuning.overlapRatio }) {
                if kept[index].value != reading.value {
                    kept[index].hasConflict = true
                }
            } else {
                kept.append(reading)
            }
        }
        return kept
    }

    /// Ignore un grand chiffre sans aucun voisin proche (bruit isolé), à partir de 3 lectures.
    private static func removeIsolated(_ readings: [Reading]) -> [Reading] {
        guard readings.count >= 3 else { return readings }
        let limit = Tuning.isolationRatio * median(readings.map(\.height))
        var kept: [Reading] = []
        for (index, reading) in readings.enumerated() {
            let hasNeighbour = readings.indices.contains { other in
                other != index && readings[other].center.distance(to: reading.center) <= limit
            }
            if hasNeighbour {
                kept.append(reading)
            }
        }
        return kept
    }

    /// Rotation de la grille, en degrés : médiane des directions vers le plus proche voisin,
    /// ramenées dans ]−45°, 45°] (voisins horizontaux comme verticaux). Au-delà du maximum : 0.
    private static func estimateSkewDegrees(_ points: [Point]) -> Double {
        guard points.count >= 2 else { return 0 }
        var angles: [Double] = []
        for (index, point) in points.enumerated() {
            var nearest: (distance: Double, point: Point)?
            for (otherIndex, other) in points.enumerated() where otherIndex != index {
                let distance = point.distance(to: other)
                if nearest.map({ distance < $0.distance }) ?? true {
                    nearest = (distance, other)
                }
            }
            guard let neighbour = nearest?.point else { continue }
            var angle = atan2(neighbour.y - point.y, neighbour.x - point.x) * 180 / .pi
            while angle > 45 { angle -= 90 }
            while angle <= -45 { angle += 90 }
            angles.append(angle)
        }
        guard !angles.isEmpty else { return 0 }
        let skew = median(angles)
        return abs(skew) <= Tuning.maximumSkewDegrees ? skew : 0
    }

    /// Indices de coin (petits chiffres) : rattachés à la carte la plus proche, ils signalent une
    /// contradiction (ex. « 9 » lu près d'un « 6 », « −2 » près d'un « 2 ») sans jamais remplir
    /// une case.
    private static func checkSecondaryReadings(
        _ secondary: [Reading],
        against cells: inout [CardScanResult.Cell: CellReading],
        pivot: Point,
        skew: Double
    ) {
        let orderedCells = cells.keys.sorted { ($0.column, $0.row) < ($1.column, $1.row) }
        for reading in secondary where reading.confidence >= Tuning.minimumConfidence {
            let point = rotate(reading.center, around: pivot, degrees: -skew)
            var nearest: (distance: Double, cell: CardScanResult.Cell)?
            for cell in orderedCells {
                guard let target = cells[cell] else { continue }
                let distance = point.distance(to: target.point)
                guard distance <= Tuning.secondaryRadiusRatio * target.reading.height else { continue }
                if nearest.map({ distance < $0.distance }) ?? true {
                    nearest = (distance, cell)
                }
            }
            if let cell = nearest?.cell, let target = cells[cell], target.reading.value != reading.value {
                cells[cell]?.isUncertain = true
            }
        }
    }

    private static func makeResult(_ cells: [CardScanResult.Cell: CellReading]) -> CardScanResult {
        var grid = CardGrid()
        var uncertain: [CardScanResult.Cell] = []
        var suggestions: [CardScanResult.Cell: Int] = [:]
        for (cell, entry) in cells {
            if entry.isUncertain {
                uncertain.append(cell)
                suggestions[cell] = entry.reading.value
            } else {
                // Valeur validée par `parseCardValue` et position 0..<4 × 0..<3 : jamais d'erreur.
                try? grid.setCard(entry.reading.value, column: cell.column, row: cell.row)
            }
        }
        uncertain.sort { ($0.column, $0.row) < ($1.column, $1.row) }
        let emptyColumns = (0..<CardGrid.columnCount).filter { column in
            !cells.keys.contains { $0.column == column }
        }
        return CardScanResult(grid: grid, uncertainCells: uncertain, suggestions: suggestions, emptyColumns: emptyColumns)
    }

    // MARK: Outils géométriques (purs)

    /// Regroupement 1D par écarts : nouvelle grappe après un écart > `threshold`, au plus
    /// `maxClusters` grappes (seuls les plus grands écarts sont alors retenus). Renvoie la grappe
    /// de chaque valeur et les centres (moyennes) croissants.
    static func clusters(of values: [Double], maxClusters: Int, threshold: Double) -> (ids: [Int], centers: [Double]) {
        guard !values.isEmpty, maxClusters >= 1 else { return (Array(repeating: 0, count: values.count), []) }
        let order = values.indices.sorted { (values[$0], $0) < (values[$1], $1) }
        var cuts: [(size: Double, position: Int)] = []
        for position in 0..<(order.count - 1) {
            let gap = values[order[position + 1]] - values[order[position]]
            if gap > threshold {
                cuts.append((gap, position))
            }
        }
        if cuts.count > maxClusters - 1 {
            cuts = Array(cuts.sorted { lhs, rhs in
                lhs.size != rhs.size ? lhs.size > rhs.size : lhs.position < rhs.position
            }.prefix(maxClusters - 1))
        }
        let cutPositions = Set(cuts.map(\.position))
        var ids = Array(repeating: 0, count: values.count)
        var current = 0
        for (position, index) in order.enumerated() {
            ids[index] = current
            if cutPositions.contains(position) { current += 1 }
        }
        var sums = Array(repeating: 0.0, count: current + 1)
        var counts = Array(repeating: 0, count: current + 1)
        for (index, id) in ids.enumerated() {
            sums[id] += values[index]
            counts[id] += 1
        }
        let centers = zip(sums, counts).map { $0 / Double(max($1, 1)) }
        return (ids, centers)
    }

    /// Place `centers` (croissants) sur `slotCount` emplacements. Moins de grappes que
    /// d'emplacements : le pas est le plus petit écart ; un écart d'environ deux pas laisse un
    /// emplacement vide (colonne retirée au milieu). Sans indice, alignement à gauche / en haut.
    static func slots(forCenters centers: [Double], slotCount: Int) -> [Int] {
        let count = centers.count
        guard count > 1 else { return Array(repeating: 0, count: count) }
        guard count < slotCount else { return Array(0..<count) }
        let gaps = zip(centers.dropFirst(), centers).map { $0 - $1 }
        guard let pitch = gaps.min(), pitch > 1e-9 else { return Array(0..<count) }
        var result = [0]
        for gap in gaps {
            let steps = min(gap / pitch, Double(slotCount)).rounded()
            result.append(result[result.count - 1] + max(1, Int(steps)))
        }
        return result[result.count - 1] <= slotCount - 1 ? result : Array(0..<count)
    }

    private static func rotate(_ point: Point, around pivot: Point, degrees: Double) -> Point {
        let radians = degrees * .pi / 180
        let dx = point.x - pivot.x
        let dy = point.y - pivot.y
        return Point(
            x: pivot.x + dx * cos(radians) - dy * sin(radians),
            y: pivot.y + dx * sin(radians) + dy * cos(radians)
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
