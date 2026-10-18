import CoreGraphics
import Foundation
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

    @Test("9 cartes, colonne de droite absente : colonne vide proposée, jamais retirée automatiquement")
    func nineCardsLeaveEmptyColumn() {
        let rows: [[Int?]] = [[1, 5, -2, nil], [0, 7, -1, nil], [9, 6, 10, nil]]
        let result = CardGridRecognizer.recognize(Self.layout(rows), imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [3])
        #expect(result.uncertainCells.isEmpty)
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
        let result = CardGridRecognizer.recognize(Self.layout(rows, angle: 8), imageAspectRatio: Self.aspect)
        #expect(Self.rows(result.grid) == rows)
        #expect(result.emptyColumns == [3])
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
        let region = Self.box(0.1, 0.15, 0.75, 0.6)
        let framed = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect, regionOfInterest: region)
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
        let result = CardGridRecognizer.recognize(observations, imageAspectRatio: Self.aspect)
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

    @Test("Singulier : 1 carte lue, 1 case sans lecture")
    func singularTexts() {
        let rows: [[Int?]] = [[nil, nil, nil, nil], [nil, 4, nil, nil], [nil, nil, nil, nil]]
        let result = CardGridRecognizer.recognize(Self.layout(rows), imageAspectRatio: Self.aspect)
        let summary = CardScanSummary(result: result, playerName: "Bob")
        #expect(summary.headline == "1\(Self.nbsp)carte lue sur 12")
        #expect(summary.title == "Cartes de Bob")
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
        let complete = CardGridRecognizer.recognize(CardScanFixture.complete.observations)
        #expect(Self.rows(complete.grid) == Self.twelveCards)
        #expect(complete.grid.evaluate().rawScore == 54)
        let partial = CardGridRecognizer.recognize(CardScanFixture.partial.observations)
        #expect(partial.recognizedCount == 8)
        #expect(partial.uncertainCells == [Cell(column: 2, row: 1)])
        #expect(partial.emptyColumns == [3])
        #expect(partial.grid.evaluate().runningTotal == 19)
    }
    #endif
}
