import CoreGraphics
import Foundation
import ImageIO
import Testing
import TableScoreKit
import UIKit
@testable import TableScore

/// Prototype P2 « Scanner les cartes » : logique **pure** (aucune caméra ni Vision ici).
///
/// Les observations simulent une photo portrait 3:4 d'une grille bien cadrée : chiffres centraux
/// de hauteur 0,065 (fraction de la hauteur d'image), pas de colonne 0,13 et de rangée 0,17
/// (en hauteurs d'image). Les règles de score restent celles du Kit (`CardGrid.evaluate()`).
@Suite("Scanner les cartes : reconnaissance de la grille")
struct CardScanTests {
    typealias Cell = CardScanResult.Cell

    private static let aspect = 0.75
    private static let digitHeight = 0.065
    private static let columnPitch = 0.13
    private static let rowPitch = 0.17
    private static let nbsp = "\u{00A0}"

    /// Rangées 1 5 −2 12 / 0 7 −1 3 / 9 6 10 4 : colonnes 10, 18, 7, 19 ⇒ 54.
    private static let twelveCards: [[Int?]] = [[1, 5, -2, 12], [0, 7, -1, 3], [9, 6, 10, 4]]

    // MARK: Outils

    /// Observation centrée en (`centerX`, `centerY`) exprimés en hauteurs d'image.
    private static func observation(
        _ candidates: [(String, Double)],
        centerX: Double,
        centerY: Double,
        height: Double = digitHeight
    ) -> CardScanObservation {
        let width = 0.6 * height * Double(candidates.first?.0.count ?? 1)
        return CardScanObservation(
            candidates: candidates.map { CardScanObservation.Candidate(text: $0.0, confidence: $0.1) },
            box: NormalizedBox(x: (centerX - width / 2) / aspect, y: centerY - height / 2, width: width / aspect, height: height)
        )
    }

    /// Grille disposée en 3 rangées × 4 colonnes, éventuellement tournée de `angle` degrés.
    private static func layout(
        _ rows: [[Int?]],
        angle: Double = 0,
        originX: Double = 0.18,
        originY: Double = 0.25,
        text: (Int) -> String = { "\($0)" }
    ) -> [CardScanObservation] {
        let centerX = originX + 1.5 * columnPitch
        let centerY = originY + rowPitch
        let radians = angle * .pi / 180
        var observations: [CardScanObservation] = []
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() {
                guard let value else { continue }
                let dx = originX + Double(column) * columnPitch - centerX
                let dy = originY + Double(row) * rowPitch - centerY
                observations.append(observation(
                    [(text(value), 1)],
                    centerX: centerX + dx * cos(radians) - dy * sin(radians),
                    centerY: centerY + dx * sin(radians) + dy * cos(radians)
                ))
            }
        }
        return observations
    }

    private static func rows(_ grid: CardGrid) -> [[Int?]] {
        (0..<CardGrid.rowCount).map { row in grid.columns.map { $0[row] } }
    }

    /// Cadre-guide exactement autour d'une grille disposée par `layout` (4 colonnes × 3 rangées).
    private static func frame(originX: Double = 0.18, originY: Double = 0.25) -> NormalizedBox {
        NormalizedBox(
            x: (originX - columnPitch / 2) / aspect,
            y: originY - rowPitch / 2,
            width: 4 * columnPitch / aspect,
            height: 3 * rowPitch
        )
    }

    private static func recognizeFramed(_ observations: [CardScanObservation]) -> CardScanResult {
        CardGridRecognizer.recognize(observations, imageAspectRatio: aspect, regionOfInterest: frame())
    }

    private static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NormalizedBox {
        NormalizedBox(x: x, y: y, width: width, height: height)
    }

    private static func isClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-6) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    // MARK: Lecture des valeurs

    @Test("Lecture d'une valeur : −2…12 uniquement, signes moins variés, bruit refusé")
    func parsesCardValues() {
        let valid: [(String, Int)] = [
            ("7", 7), ("12", 12), ("0", 0), ("-2", -2), ("\u{2212}1", -1), ("\u{2014}2", -2),
            ("\u{2013}1", -1), (" 6. ", 6), ("- 2", -2), ("9_", 9)
        ]
        for (text, expected) in valid {
            #expect(CardGridRecognizer.parseCardValue(text) == expected, "« \(text) »")
        }
        let invalid = ["13", "-3", "05", "-0", "100", "", "-", "a", "1 2", "SKYJO", "\u{0661}", "7a", "--2"]
        for text in invalid {
            #expect(CardGridRecognizer.parseCardValue(text) == nil, "« \(text) »")
        }
    }

    @Test("Découpage d'une ligne en mots : signe isolé rattaché au nombre suivant")
    func tokenRangesKeepDetachedSigns() {
        func words(_ text: String) -> [String] {
            CardGridRecognizer.tokenRanges(in: text).map { String(text[$0]) }
        }
        #expect(words("5 7") == ["5", "7"])
        #expect(words("- 2 8") == ["- 2", "8"])
        #expect(words("  12  ") == ["12"])
        #expect(words("-") == ["-"])
        #expect(words("") == [])
    }

    // MARK: Grille

    @Test("12 valeurs nettes : grille complète, rien à vérifier, total du Kit 54")
    func twelveClearValuesGiveCompleteGrid() {
        let result = CardGridRecognizer.recognize(Self.layout(Self.twelveCards), imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == Self.twelveCards)
        #expect(result.uncertainCells.isEmpty)
        #expect(result.emptyColumns.isEmpty)
        #expect(result.recognizedCount == 12)
        #expect(result.grid.evaluate().rawScore == 54)
        #expect(result.grid.columns.allSatisfy { !$0.isMarkedRemoved })
    }

    @Test("Valeurs négatives lues avec divers signes moins", arguments: ["-", "\u{2212}", "\u{2014}", "\u{2013}", "- "])
    func negativeValuesWithVariousSigns(sign: String) {
        let observations = Self.layout(Self.twelveCards) { value in
            value < 0 ? "\(sign)\(-value)" : "\(value)"
        }
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == Self.twelveCards)
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("Bruit hors plage ou non numérique ignoré (13, 100, texte)")
    func noiseIsIgnored() {
        let noise = [
            CardScanObservation(candidates: [.init(text: "13", confidence: 1)], box: Self.box(0.1, 0.05, 0.1, 0.06)),
            CardScanObservation(candidates: [.init(text: "SKYJO", confidence: 1)], box: Self.box(0.4, 0.9, 0.3, 0.06)),
            CardScanObservation(candidates: [.init(text: "100", confidence: 1)], box: Self.box(0.6, 0.05, 0.2, 0.06)),
            CardScanObservation(candidates: [.init(text: "7", confidence: 1)], box: Self.box(.nan, 0.5, 0.1, 0.06))
        ]
        let result = CardGridRecognizer.recognize(Self.layout(Self.twelveCards) + noise, imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == Self.twelveCards)
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("9 cartes, colonne de droite absente (avec cadre) : colonne vide proposée, jamais retirée automatiquement")
    func nineCardsLeaveEmptyColumn() {
        let rows: [[Int?]] = [[1, 5, -2, nil], [0, 7, -1, nil], [9, 6, 10, nil]]
        let result = Self.recognizeFramed(Self.layout(rows))
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [3])
        #expect(result.uncertainCells.isEmpty)
        #expect(result.misplacedCells.isEmpty)
        #expect(!result.grid.columns[3].isMarkedRemoved)
        // L'utilisateur marque la colonne retirée : la grille devient validable.
        var grid = result.grid
        try? grid.setColumnRemoved(true, column: 3)
        #expect(grid.evaluate().rawScore == 35)

        let summary = CardScanSummary(result: result, playerName: "Alice")
        #expect(summary.notes.contains {
            $0.kind == .info && $0.text.hasPrefix("Colonne 4\(Self.nbsp): aucune carte lue.")
                && $0.text.contains("«\(Self.nbsp)Colonne retirée\(Self.nbsp)»")
        })
    }

    @Test("Colonne du milieu absente (écart conservé) : la colonne vide reste à sa place")
    func emptyMiddleColumnKeepsItsPlace() {
        let rows: [[Int?]] = [[1, nil, 5, -2], [0, nil, 7, -1], [9, nil, 6, 10]]
        let result = CardGridRecognizer.recognize(Self.layout(rows), imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [1])
    }

    @Test("Rotation légère de la photo tolérée", arguments: [3.0, 8.0, -10.0, 14.0, -14.0])
    func slightRotationIsTolerated(angle: Double) {
        let result = CardGridRecognizer.recognize(Self.layout(Self.twelveCards, angle: angle), imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == Self.twelveCards)
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("Rotation légère et colonne vide combinées")
    func rotationWithEmptyColumn() {
        let rows: [[Int?]] = [[1, 5, -2, nil], [0, 7, -1, nil], [9, 6, 10, nil]]
        let result = Self.recognizeFramed(Self.layout(rows, angle: 8))
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [3])
        #expect(result.uncertainCells.isEmpty)
    }

    // MARK: Placement par le cadre-guide

    @Test("Avec cadre : colonne 1 absente, les 3 autres restent à leur place (2, 3, 4)")
    func firstColumnMissingWithFrame() {
        let rows: [[Int?]] = [[nil, 5, -2, 12], [nil, 7, -1, 3], [nil, 6, 10, 4]]
        let result = Self.recognizeFramed(Self.layout(rows))
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [0])
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("Avec cadre : seules les colonnes 1 et 3 sont lues, à leur place")
    func columnsOneAndThreeWithFrame() {
        let rows: [[Int?]] = [[1, nil, -2, nil], [0, nil, -1, nil], [9, nil, 10, nil]]
        let result = Self.recognizeFramed(Self.layout(rows))
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [1, 3])
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("Avec cadre : rangée du milieu absente, rangées 1 et 3 à leur place")
    func middleRowMissingWithFrame() {
        let rows: [[Int?]] = [[1, 5, -2, 12], [nil, nil, nil, nil], [9, 6, 10, 4]]
        let result = Self.recognizeFramed(Self.layout(rows))
        #expect(Self.rows(result.grid) == rows)
        #expect(result.uncertainCells.isEmpty)
        #expect(result.emptyColumns.isEmpty)
    }

    @Test("Sans cadre, rangée du milieu absente : places devinées, cases à vérifier et note")
    func middleRowMissingWithoutFrame() {
        let rows: [[Int?]] = [[1, 5, -2, 12], [nil, nil, nil, nil], [9, 6, 10, 4]]
        let result = CardGridRecognizer.recognize(Self.layout(rows), imageAspectRatio: Self.aspect)
        #expect(result.recognizedCount == 0, "Aucune valeur placée à une place devinée.")
        #expect(result.uncertainCells.count == 8)
        #expect(result.misplacedCells == result.uncertainCells)
        let summary = CardScanSummary(result: result, playerName: "Alice")
        #expect(summary.headline == "0\(Self.nbsp)carte lue sur 12")
        #expect(summary.notes.first?.text == CardScanSummary.positionsToVerifyText)
        #expect(summary.notes.dropFirst().first?.text.contains("position incertaine") == true)
    }

    @Test("Sans cadre, colonnes 1 et 3 seules : places devinées, à vérifier")
    func columnsOneAndThreeWithoutFrame() {
        let rows: [[Int?]] = [[1, nil, -2, nil], [0, nil, -1, nil], [9, nil, 10, nil]]
        let result = CardGridRecognizer.recognize(Self.layout(rows), imageAspectRatio: Self.aspect)
        #expect(result.recognizedCount == 0)
        #expect(result.misplacedCells.count == 6)
    }

    @Test("Places du cadre : bornées, strictement croissantes, déplacements signalés")
    func geometricSlots() {
        let regular = CardGridRecognizer.geometricSlots(centers: [0.1, 0.6, 0.9], origin: 0, length: 1, slotCount: 4)
        #expect(regular.slots == [0, 2, 3])
        #expect(regular.adjusted.isEmpty)
        // Deux grappes dans le même quart : la seconde est poussée, et signalée.
        let crowded = CardGridRecognizer.geometricSlots(centers: [0.1, 0.2], origin: 0, length: 1, slotCount: 4)
        #expect(crowded.slots == [0, 1])
        #expect(crowded.adjusted == [1])
        // Hors cadre à droite : bornée à la dernière place, la précédente recule.
        let overflow = CardGridRecognizer.geometricSlots(centers: [0.8, 1.4], origin: 0, length: 1, slotCount: 3)
        #expect(overflow.slots == [1, 2])
        #expect(overflow.adjusted == [0])
        let invalid = CardGridRecognizer.geometricSlots(centers: [0.5], origin: 0, length: 0, slotCount: 3)
        #expect(invalid.slots == [0])
        #expect(invalid.adjusted == [0])
    }

    // MARK: Doublons et incertitudes

    @Test("Même carte lue deux fois (boîtes superposées, même valeur) : une seule valeur, sûre")
    func overlappingDuplicateWithSameValue() {
        var observations = Self.layout(Self.twelveCards)
        let original = observations[5].box // rangée 2, colonne 2 : 7
        observations.append(CardScanObservation(
            candidates: [.init(text: "7", confidence: 0.9)],
            box: Self.box(original.x + 0.002, original.y + 0.002, original.width, original.height)
        ))
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == Self.twelveCards)
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("Lectures superposées contradictoires : case vide à confirmer, lecture probable suggérée")
    func overlappingConflictingReadings() {
        var observations = Self.layout(Self.twelveCards)
        let original = observations[5].box
        observations.append(CardScanObservation(
            candidates: [.init(text: "1", confidence: 0.9)],
            box: Self.box(original.x + 0.002, original.y + 0.002, original.width, original.height)
        ))
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        let cell = Cell(column: 1, row: 1)
        #expect(result.uncertainCells == [cell])
        #expect(result.grid.columns[1][1] == nil)
        #expect(result.suggestions[cell] == 7)
        #expect(result.recognizedCount == 11)
    }

    @Test("Confiance faible : case laissée vide et à confirmer")
    func lowConfidenceLeavesCellEmpty() {
        var observations = Self.layout(Self.twelveCards)
        observations[5] = CardScanObservation(candidates: [.init(text: "7", confidence: 0.3)], box: observations[5].box)
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        let cell = Cell(column: 1, row: 1)
        #expect(result.uncertainCells == [cell])
        #expect(result.grid.columns[1][1] == nil)
        #expect(result.suggestions[cell] == 7)
        #expect(result.grid.evaluate().rawScore == nil, "Grille non validable tant que la case n'est pas confirmée.")
    }

    @Test("« 6 » ou « 9 » de confiances proches : case à confirmer")
    func ambiguousSixOrNine() {
        var observations = Self.layout(Self.twelveCards)
        observations[11] = CardScanObservation(
            candidates: [.init(text: "6", confidence: 0.6), .init(text: "9", confidence: 0.55)],
            box: observations[11].box
        )
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        let cell = Cell(column: 3, row: 2)
        #expect(result.uncertainCells == [cell])
        #expect(result.suggestions[cell] == 6)
    }

    @Test("Indices de coin cohérents : aucune incertitude ajoutée")
    func consistentCornerIndices() {
        var observations = Self.layout(Self.twelveCards)
        for observation in observations {
            let box = observation.box
            observations.append(CardScanObservation(
                candidates: observation.candidates,
                box: Self.box(box.x - 0.03, box.y - 0.05, box.width * 0.3, box.height * 0.3)
            ))
        }
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == Self.twelveCards)
        #expect(result.uncertainCells.isEmpty)
    }

    @Test("Indice de coin contradictoire (« 9 » près d'un « 6 ») : case à confirmer")
    func contradictoryCornerIndex() {
        var observations = Self.layout(Self.twelveCards)
        let six = observations[9].box // rangée 3, colonne 2 : 6
        observations.append(CardScanObservation(
            candidates: [.init(text: "9", confidence: 1)],
            box: Self.box(six.x + 0.03, six.y + 0.07, six.width * 0.3, six.height * 0.3)
        ))
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        let cell = Cell(column: 1, row: 2)
        #expect(result.uncertainCells == [cell])
        #expect(result.suggestions[cell] == 6)
    }

    @Test("Signe moins lu séparément : valeur négative proposée, mais à confirmer")
    func detachedMinusSign() {
        var observations = Self.layout(Self.twelveCards)
        let minusTwo = observations[2].box // rangée 1, colonne 3 : −2
        observations[2] = CardScanObservation(
            candidates: [.init(text: "2", confidence: 1)],
            box: Self.box(minusTwo.x + minusTwo.width * 0.4, minusTwo.y, minusTwo.width * 0.6, minusTwo.height)
        )
        observations.append(CardScanObservation(
            candidates: [.init(text: "-", confidence: 1)],
            box: Self.box(minusTwo.x, minusTwo.y + minusTwo.height * 0.4, minusTwo.width * 0.3, minusTwo.height * 0.15)
        ))
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        let cell = Cell(column: 2, row: 0)
        #expect(result.uncertainCells == [cell])
        #expect(result.suggestions[cell] == -2)
    }

    @Test("Cadre-guide : les cartes d'un voisin hors du cadre sont ignorées")
    func regionOfInterestIgnoresNeighbourCards() {
        let neighbour = Self.layout([[2, 2], [3, 3], [4, 4]], originX: 0.85)
        let observations = Self.layout(Self.twelveCards) + neighbour
        let framed = Self.recognizeFramed(observations)
        #expect(Self.rows(framed.grid) == Self.twelveCards)
        #expect(framed.uncertainCells.isEmpty)
        let unframed = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        #expect(Self.rows(unframed.grid) != Self.twelveCards)
    }

    @Test("Aucune observation : résultat vide, 4 colonnes vides")
    func emptyInput() {
        let result = CardGridRecognizer.recognize([])
        #expect(result == .empty)
        #expect(result.detectedCount == 0)
        let summary = CardScanSummary(result: result, playerName: "Bob")
        #expect(summary.headline == "Aucune carte lue")
        #expect(summary.verifyText == nil)
        #expect(summary.notes.count == 1)
        #expect(summary.notes.first?.kind == .warning)
        #expect(summary.announcement == "Aucune carte lue. Reprenez la photo.")
    }

    @Test("Déterministe : même entrée, même résultat, quel que soit l'ordre des observations")
    func recognitionIsDeterministic() {
        let observations = Self.layout(Self.twelveCards, angle: 8)
        let first = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
        let second = CardGridRecognizer.recognize(Array(observations.reversed()), imageAspectRatio: Self.aspect)
        #expect(first == second)
    }

    // MARK: Textes de vérification

    @Test("Bilan, notes et annonce VoiceOver d'une lecture partielle")
    func summaryTexts() {
        var observations = Self.layout([[3, 3, 8, nil], [3, 5, nil, nil], [3, 2, 1, nil]])
        observations.append(Self.observation(
            [("6", 0.6), ("9", 0.55)],
            centerX: 0.18 + 2 * Self.columnPitch,
            centerY: 0.25 + Self.rowPitch
        ))
        let result = Self.recognizeFramed(observations)
        let summary = CardScanSummary(result: result, playerName: "Alice")
        #expect(summary.title == "Cartes d'Alice")
        #expect(summary.headline == "8\(Self.nbsp)cartes lues sur 12")
        #expect(summary.verifyText == "1\(Self.nbsp)case à vérifier")
        #expect(summary.unreadCellCount == 0)
        #expect(summary.notes.map(\.kind) == [.warning, .info])
        #expect(summary.notes.first?.text
            == "Colonne 3, rangée 2\(Self.nbsp): lecture incertaine (6\u{202F}?), choisissez la valeur.")
        #expect(summary.announcement
            == "8\(Self.nbsp)cartes lues sur 12, 1\(Self.nbsp)case à vérifier. Vérifiez la grille avant de l'utiliser.")
        // Totaux toujours calculés par le Kit : colonne 3/3/3 non comptée, total provisoire 19.
        let evaluation = result.grid.evaluate()
        #expect(evaluation.columns[0] == .identicalCards(value: 3))
        #expect(evaluation.runningTotal == 19)
        #expect(evaluation.missingCardCount == 4)
    }

    @Test("Une seule carte, avec cadre : placée en colonne 2, rangée 2 ; texte au singulier")
    func singleCardWithFrame() {
        let rows: [[Int?]] = [[nil, nil, nil, nil], [nil, 4, nil, nil], [nil, nil, nil, nil]]
        let result = Self.recognizeFramed(Self.layout(rows))
        #expect(Self.rows(result.grid) == rows)
        #expect(result.uncertainCells.isEmpty)
        let summary = CardScanSummary(result: result, playerName: "Bob")
        #expect(summary.headline == "1\(Self.nbsp)carte lue sur 12")
        #expect(summary.title == "Cartes de Bob")
    }

    @Test("Une seule carte, sans cadre : place devinée, case à vérifier")
    func singleCardWithoutFrame() {
        let rows: [[Int?]] = [[nil, nil, nil, nil], [nil, 4, nil, nil], [nil, nil, nil, nil]]
        let result = CardGridRecognizer.recognize(Self.layout(rows), imageAspectRatio: Self.aspect)
        #expect(result.recognizedCount == 0)
        #expect(result.misplacedCells.count == 1)
        #expect(result.suggestions.values.first == 4)
    }

    @Test("Jamais d'écrasement silencieux : confirmation si des cartes sont déjà saisies")
    func replaceConfirmation() throws {
        #expect(!CardScanSummary.needsReplaceConfirmation(current: CardGrid()))
        var withCard = CardGrid()
        try withCard.setCard(5, column: 0, row: 0)
        #expect(CardScanSummary.needsReplaceConfirmation(current: withCard))
        var withRemovedColumn = CardGrid()
        try withRemovedColumn.setColumnRemoved(true, column: 2)
        #expect(CardScanSummary.needsReplaceConfirmation(current: withRemovedColumn))
        #expect(!CardScanSummary.canUse(CardGrid()))
        #expect(CardScanSummary.canUse(withCard))
        #expect(CardScanSummary.replaceTitle == "Remplacer les cartes saisies\u{202F}?")
    }

    // MARK: Géométrie, orientation, identifiants

    @Test("Cadre-guide : rapport 4 × 3 cartes, centré, dans la vue")
    func guideRectFitsView() {
        let portrait = CardScanGeometry.guideRect(in: CGSize(width: 400, height: 600))
        #expect(Self.isClose(Double(portrait.width), 352))
        #expect(Self.isClose(Double(portrait.width / portrait.height), Double(CardScanGeometry.guideAspectRatio)))
        #expect(Self.isClose(Double(portrait.midX), 200))
        #expect(Self.isClose(Double(portrait.midY), 300))
        let landscape = CardScanGeometry.guideRect(in: CGSize(width: 800, height: 400))
        #expect(Self.isClose(Double(landscape.height), 352))
        #expect(landscape.minX >= 0 && landscape.maxX <= 800)
    }

    @Test("Zone du cadre dans la photo (aperçu rogné « aspect fill »)")
    func regionOfInterestMapping() throws {
        // Vue plus étroite que la photo (0,65 < 0,75) : bords gauche et droit rognés.
        let narrow = try #require(CardScanGeometry.regionOfInterest(
            guide: CGRect(x: 0, y: 0, width: 390, height: 600),
            viewSize: CGSize(width: 390, height: 600),
            imageAspectRatio: 0.75
        ))
        #expect(Self.isClose(narrow.width, 0.65 / 0.75))
        #expect(Self.isClose(narrow.x, (1 - 0.65 / 0.75) / 2))
        #expect(Self.isClose(narrow.y, 0))
        #expect(Self.isClose(narrow.height, 1))
        // Vue plus large que la photo (paysage 1,5 > 4/3) : haut et bas rognés.
        let wide = try #require(CardScanGeometry.regionOfInterest(
            guide: CGRect(x: 0, y: 0, width: 600, height: 400),
            viewSize: CGSize(width: 600, height: 400),
            imageAspectRatio: 4.0 / 3.0
        ))
        #expect(Self.isClose(wide.height, (4.0 / 3.0) / 1.5))
        #expect(Self.isClose(wide.x, 0))
        #expect(CardScanGeometry.regionOfInterest(guide: .zero, viewSize: .zero, imageAspectRatio: 0.75) == nil)
    }

    @Test("Conversion d'une boîte Vision (origine en bas à gauche)")
    func visionRectIsFlipped() {
        let box = NormalizedBox(visionRect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        #expect(Self.isClose(box.x, 0.1))
        #expect(Self.isClose(box.y, 0.4))
        #expect(Self.isClose(box.width, 0.3))
        #expect(Self.isClose(box.height, 0.4))
    }

    @Test("Rotation de la caméra arrière selon l'orientation de l'interface")
    func rotationAngles() {
        #expect(CardScanCamera.rotationAngle(for: .portrait) == 90)
        #expect(CardScanCamera.rotationAngle(for: .landscapeRight) == 0)
        #expect(CardScanCamera.rotationAngle(for: .landscapeLeft) == 180)
        #expect(CardScanCamera.rotationAngle(for: .portraitUpsideDown) == 270)
        #expect(CardScanCamera.rotationAngle(for: .unknown) == 90)
    }

    @Test("Identifiants d'accessibilité du scan figés")
    func accessibilityIdentifiers() {
        #expect(AccessibilityID.Scan.start(position: 2) == "scan.start.2")
        #expect(AccessibilityID.Scan.cancel == "scan.cancel")
        #expect(AccessibilityID.Scan.capture == "scan.capture")
        #expect(AccessibilityID.Scan.message == "scan.message")
        #expect(AccessibilityID.Scan.summary == "scan.review.summary")
        #expect(AccessibilityID.Scan.notes == "scan.review.notes")
        #expect(AccessibilityID.Scan.use == "scan.review.use")
        #expect(AccessibilityID.Scan.retake == "scan.review.retake")
        #expect(AccessibilityID.Scan.confirmReplace == "scan.review.confirmReplace")
    }

    // MARK: Adaptateur Vision et caméra (parties pures)

    @Test("Ligne multi-mots : 3 lectures candidates conservées mot par mot (ambiguïté 6/9)")
    func wordCandidatesKeepAmbiguity() {
        let words = CardGridRecognizer.wordCandidates([
            .init(text: "5 6", confidence: 0.6),
            .init(text: "5 9", confidence: 0.55),
            .init(text: "56", confidence: 0.5)
        ])
        #expect(words.map { $0.map(\.text) } == [["5", "5"], ["6", "9"]])
        #expect(words[1].map(\.confidence) == [0.6, 0.55])
        #expect(CardGridRecognizer.wordCandidates([.init(text: "- 2 8", confidence: 1)]).map { $0.map(\.text) }
            == [["- 2"], ["8"]])
        #expect(CardGridRecognizer.wordCandidates([]).isEmpty)
    }

    @Test("Zone analysée par Vision : cadre élargi, borné, origine en bas à gauche ; retour à l'image entière")
    func visionRegionRoundTrip() {
        let region = CardScanGeometry.visionRegion(for: Self.box(0.2, 0.1, 0.5, 0.6), margin: 0.05)
        #expect(Self.isClose(Double(region.minX), 0.15))
        #expect(Self.isClose(Double(region.minY), 0.25))
        #expect(Self.isClose(Double(region.width), 0.6))
        #expect(Self.isClose(Double(region.height), 0.7))
        let clamped = CardScanGeometry.visionRegion(for: Self.box(0.98, 0.9, 0.1, 0.2), margin: 0.05)
        #expect(Self.isClose(Double(clamped.maxX), 1))
        #expect(Self.isClose(Double(clamped.minY), 0))
        let box = NormalizedBox(
            visionRect: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
            within: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        )
        #expect(Self.isClose(box.x, 0.35))
        #expect(Self.isClose(box.y, 0.52))
        #expect(Self.isClose(box.width, 0.1))
        #expect(Self.isClose(box.height, 0.08))
    }

    @Test("Taille de photo : la plus grande ≤ 4032 px, sinon la plus petite")
    func preferredPhotoDimensions() {
        let sizes = [(width: 4032, height: 3024), (width: 8064, height: 6048), (width: 1920, height: 1080)]
        #expect(CardScanCamera.preferredPhotoDimensionsIndex(sizes, maximumSide: 4032) == 0)
        let large = [(width: 8064, height: 6048), (width: 5712, height: 4284)]
        #expect(CardScanCamera.preferredPhotoDimensionsIndex(large, maximumSide: 4032) == 1)
        #expect(CardScanCamera.preferredPhotoDimensionsIndex([], maximumSide: 4032) == nil)
    }

    @Test("Rapport largeur / hauteur de la photo redressée selon l'orientation EXIF")
    func uprightAspectRatio() throws {
        let photo = try #require(ScanTestPhoto.make(orientation: .right))
        #expect(Self.isClose(photo.uprightAspectRatio, 0.75))
        let upright = try #require(ScanTestPhoto.make(orientation: .up))
        #expect(Self.isClose(upright.uprightAspectRatio, 4.0 / 3.0))
    }

    // MARK: Déroulement (caméra et lecture simulées)

    private static let emptyOutput = CardScanTextReader.Output(observations: [], imageAspectRatio: 0.75, regionOfInterest: nil)

    @Test("Caméra coupée juste après la photo, AVANT la lecture")
    @MainActor
    func cameraStopsBeforeReading() async {
        let log = ScanEventLog()
        let model = CardScanModel(camera: FakeScanCamera(log: log), access: { .granted }, reader: { _, _ in
            log.append("read")
            return Self.emptyOutput
        })
        await model.start()
        #expect(model.phase == .capturing)
        await model.capture(region: nil)
        #expect(log.events == ["start", "capture", "stop", "read"])
        #expect(model.phase == .review(.empty))
        #expect(model.resultCount == 1)
    }

    @Test("Échec de la photo : caméra coupée, aucune lecture, message")
    @MainActor
    func captureFailureStopsCamera() async {
        let log = ScanEventLog()
        let model = CardScanModel(camera: FakeScanCamera(log: log, failsCapture: true), access: { .granted }, reader: { _, _ in
            log.append("read")
            return Self.emptyOutput
        })
        await model.start()
        await model.capture(region: nil)
        #expect(log.events == ["start", "capture", "stop"])
        #expect(model.phase == .failed)
    }

    @Test("Autorisation refusée ou limitée : caméra jamais démarrée", arguments: [CardScanAccess.denied, .restricted])
    @MainActor
    func refusedAccessNeverStartsCamera(access: CardScanAccess) async {
        let log = ScanEventLog()
        let model = CardScanModel(camera: FakeScanCamera(log: log), access: { access })
        await model.start()
        #expect(log.events.isEmpty)
        let expected: CardScanModel.Phase = access == .denied ? .denied : .restricted
        #expect(model.phase == expected)
    }

    @Test("Sans appareil photo : indisponible")
    @MainActor
    func missingCameraIsUnavailable() async {
        let model = CardScanModel(camera: nil, access: { .granted })
        await model.start()
        #expect(model.phase == .unavailable)
    }

    @Test("Interruption pendant l'aperçu, puis reprise")
    @MainActor
    func interruptionAndResume() async {
        let model = CardScanModel(camera: FakeScanCamera(log: ScanEventLog()), access: { .granted })
        await model.start()
        model.interruptionChanged(true)
        #expect(model.phase == .interrupted)
        model.interruptionChanged(false)
        #expect(model.phase == .capturing)
        // Hors aperçu, une interruption ne change rien.
        model.interruptionChanged(false)
        #expect(model.phase == .capturing)
    }

    @Test("Résultat fourni (sans caméra) : passe par le recognizer avec son cadre")
    @MainActor
    func fixtureOutputGoesThroughRecognizer() async {
        let output = CardScanTextReader.Output(
            observations: Self.layout([[1, 5, -2, nil], [0, 7, -1, nil], [9, 6, 10, nil]]),
            imageAspectRatio: Self.aspect,
            regionOfInterest: Self.frame()
        )
        let model = CardScanModel(camera: nil, fixtureOutput: output)
        await model.start()
        guard case .review(let result) = model.phase else {
            Issue.record("Vérification attendue, reçu \(model.phase)")
            return
        }
        #expect(result.recognizedCount == 9)
        #expect(result.emptyColumns == [3])
    }

    #if DEBUG
    @Test("Résultats simulés (tests UI) : exigent -uiTesting et un nom connu")
    func fixtureLaunchArguments() {
        #expect(CardScanFixture.requested(in: ["-uiTesting", "-scanFixture", "complete"]) == .complete)
        #expect(CardScanFixture.requested(in: ["-scanFixture", "complete"]) == nil)
        #expect(CardScanFixture.requested(in: ["-uiTesting", "-scanFixture", "inconnu"]) == nil)
        #expect(CardScanFixture.requested(in: ["-uiTesting", "-scanFixture"]) == nil)
    }

    @Test("Résultats simulés : grille complète (54) et lecture partielle (19 provisoire, 1 case à vérifier)")
    func fixtureResults() {
        func recognize(_ output: CardScanTextReader.Output) -> CardScanResult {
            CardGridRecognizer.recognize(
                output.observations,
                imageAspectRatio: output.imageAspectRatio,
                regionOfInterest: output.regionOfInterest
            )
        }
        let complete = recognize(CardScanFixture.complete.output)
        #expect(Self.rows(complete.grid) == Self.twelveCards)
        #expect(complete.grid.evaluate().rawScore == 54)
        let partial = recognize(CardScanFixture.partial.output)
        #expect(partial.misplacedCells.isEmpty)
        #expect(partial.recognizedCount == 8)
        #expect(partial.uncertainCells == [Cell(column: 2, row: 1)])
        #expect(partial.emptyColumns == [3])
        #expect(partial.grid.evaluate().runningTotal == 19)
    }
    #endif
}

// MARK: - Doubles de test

/// Journal d'événements partagé entre la caméra simulée et la lecture simulée.
private final class ScanEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.withLock { storage.append(event) }
    }

    var events: [String] {
        lock.withLock { storage }
    }
}

/// Caméra simulée : journalise start / capture / stop, photo minuscule en mémoire.
private final class FakeScanCamera: CardScanCapturing, @unchecked Sendable {
    private let log: ScanEventLog
    private let failsCapture: Bool

    init(log: ScanEventLog, failsCapture: Bool = false) {
        self.log = log
        self.failsCapture = failsCapture
    }

    func start() async throws {
        log.append("start")
    }

    func capturePhoto() async throws -> CapturedPhoto {
        log.append("capture")
        guard !failsCapture, let photo = ScanTestPhoto.make(orientation: .right) else {
            throw CardScanCamera.Failure.captureFailed
        }
        return photo
    }

    func stop() {
        log.append("stop")
    }

    func setInterruptionHandler(_ handler: (@Sendable (Bool) -> Void)?) {}
}

private enum ScanTestPhoto {
    /// Image 4 × 3 px en mémoire.
    static func make(orientation: CGImagePropertyOrientation) -> CapturedPhoto? {
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 3,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else { return nil }
        return CapturedPhoto(image: image, orientation: orientation)
    }
}
