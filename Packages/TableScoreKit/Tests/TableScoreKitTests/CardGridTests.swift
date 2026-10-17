import Foundation
import Testing
import TableScoreKit

@Suite("Grille de cartes (§3.3, §10 n° 5–6)")
struct CardGridTests {

    @Test("§10 n° 5 : colonne 7/7/7 ⇒ 0")
    func identicalSevensRemoved() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]])
        let evaluation = grid.evaluate()
        #expect(evaluation.columns[0] == .identicalCards(value: 7))
        #expect(evaluation.rawScore == 48) // 13 + 16 + 19
    }

    @Test("§10 n° 5 : colonne −2/−2/−2 ⇒ 0 (retirée même négative)")
    func identicalNegativesRemoved() throws {
        let grid = try CardGrid(rows: [[-2, 1, 2, 3], [-2, 4, 5, 6], [-2, 8, 9, 10]])
        let evaluation = grid.evaluate()
        #expect(evaluation.columns[0] == .identicalCards(value: -2))
        #expect(evaluation.rawScore == 48)
    }

    @Test("§10 n° 5 : ligne horizontale 5/5/5/5 ⇒ jamais retirée")
    func horizontalLineNotRemoved() throws {
        let grid = try CardGrid(rows: [[5, 5, 5, 5], [1, 2, 3, 4], [0, -1, 6, 12]])
        let evaluation = grid.evaluate()
        #expect(evaluation.columns == [.counted(sum: 6), .counted(sum: 6), .counted(sum: 14), .counted(sum: 21)])
        #expect(evaluation.rawScore == 47)
    }

    @Test("§10 n° 6 : colonne complétée au dernier dévoilement ⇒ retrait pris en compte")
    func finalRevealCompletesTriple() throws {
        var grid = try CardGrid(rows: [[4, 1, 2, 3], [4, 4, 5, 6], [nil, 8, 9, 10]])
        #expect(grid.evaluate().rawScore == nil)
        #expect(grid.evaluate().columns[0] == .incomplete(enteredSum: 8, missingCount: 1))
        #expect(grid.evaluate().runningTotal == 56) // 8 + 13 + 16 + 19 en direct

        try grid.setCard(4, column: 0, row: 2)
        #expect(grid.evaluate().columns[0] == .identicalCards(value: 4))
        #expect(grid.evaluate().rawScore == 48)
    }

    @Test("§10 n° 6 : colonne marquée retirée ⇒ 0 sans double retrait")
    func markedRemovedColumnNoDoubleRemoval() throws {
        let grid = try CardGrid(rows: [[nil, 1, 2, 3], [nil, 4, 5, 6], [nil, 8, 9, 10]], removedColumns: [0])
        let evaluation = grid.evaluate()
        #expect(evaluation.columns[0] == .markedRemoved)
        #expect(evaluation.rawScore == 48)

        // Valeurs identiques conservées dans une colonne marquée retirée : comptée 0 une seule fois.
        let withValues = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]], removedColumns: [0])
        #expect(withValues.evaluate().columns[0] == .markedRemoved)
        #expect(withValues.evaluate().rawScore == 48)
    }

    @Test("Retirer puis rétablir une colonne conserve les valeurs saisies")
    func toggleRemovalKeepsValues() throws {
        var grid = try CardGrid(rows: [[1, 1, 2, 3], [2, 4, 5, 6], [3, 8, 9, 10]])
        try grid.setColumnRemoved(true, column: 0)
        #expect(grid.evaluate().rawScore == 48)
        try grid.setColumnRemoved(false, column: 0)
        #expect(grid.evaluate().rawScore == 54)
        #expect(grid.columns[0].values == [1, 2, 3])
    }

    @Test("Toutes les colonnes retirées ⇒ 0")
    func allColumnsRemoved() throws {
        let grid = try CardGrid(rows: [[nil, nil, nil, nil], [nil, nil, nil, nil], [nil, nil, nil, nil]],
                                removedColumns: [0, 1, 2, 3])
        #expect(grid.evaluate().rawScore == 0)
    }

    @Test("Zéro est une vraie valeur, distincte d'une case vide")
    func zeroIsNotEmpty() throws {
        var grid = try CardGrid(rows: [[0, 1, 2, 3], [1, 4, 5, 6], [nil, 8, 9, 10]])
        #expect(grid.evaluate().rawScore == nil)
        #expect(grid.evaluate().missingCardCount == 1)
        try grid.setCard(0, column: 0, row: 2)
        #expect(grid.columns[0][2] == 0)
        #expect(grid.evaluate().rawScore == 49) // 1 + 13 + 16 + 19
    }

    @Test("Grille vide : 12 cartes manquantes, validation impossible")
    func emptyGridIsIncomplete() {
        let evaluation = CardGrid().evaluate()
        #expect(evaluation.missingCardCount == 12)
        #expect(!evaluation.isComplete)
        #expect(evaluation.rawScore == nil)
        #expect(evaluation.runningTotal == 0)
    }

    @Test("Valeurs hors −2…12 refusées", arguments: [-3, 13, Int.min, Int.max])
    func outOfRangeValuesRejected(value: Int) {
        #expect(throws: ValidationError.cardValueOutOfRange(value)) {
            var grid = CardGrid()
            try grid.setCard(value, column: 0, row: 0)
        }
    }

    @Test("Bornes −2 et 12 acceptées")
    func boundaryValuesAccepted() throws {
        var grid = CardGrid()
        try grid.setCard(-2, column: 3, row: 0)
        try grid.setCard(12, column: 3, row: 2)
        #expect(grid.columns[3].values == [-2, nil, 12])
    }

    @Test("Positions hors grille refusées")
    func outOfRangePositionsRejected() {
        #expect(throws: ValidationError.cardPositionOutOfRange(column: 4, row: 0)) {
            var grid = CardGrid()
            try grid.setCard(1, column: 4, row: 0)
        }
        #expect(throws: ValidationError.cardPositionOutOfRange(column: 0, row: 3)) {
            var grid = CardGrid()
            try grid.setCard(1, column: 0, row: 3)
        }
        #expect(throws: ValidationError.cardPositionOutOfRange(column: -1, row: 0)) {
            var grid = CardGrid()
            try grid.setColumnRemoved(true, column: -1)
        }
    }

    @Test("Forme de grille invalide refusée")
    func invalidShapeRejected() {
        #expect(throws: ValidationError.invalidGridShape) {
            try CardGrid(rows: [[1, 2, 3, 4], [1, 2, 3, 4]])
        }
        #expect(throws: ValidationError.invalidGridShape) {
            try CardGrid(rows: [[1, 2, 3], [1, 2, 3], [1, 2, 3]])
        }
        #expect(throws: ValidationError.invalidGridShape) {
            try CardGrid(rows: [[1, 2, 3, 4], [1, 2, 3, 4], [1, 2, 3, 4]], removedColumns: [4])
        }
        #expect(throws: ValidationError.invalidGridShape) {
            try CardGrid(columns: [CardColumn.empty])
        }
    }

    @Test("Entrée cartes : score brut dérivé de la grille")
    func cardsEntryDerivesRawScore() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]])
        let entry = try RoundEntry.cards(Fx.alice, grid: grid)
        #expect(entry.rawScore == 48)
        #expect(entry.inputMethod == .cards)
        #expect(entry.cardGrid == grid)
    }

    @Test("Codable : aller-retour fidèle")
    func codableRoundTrip() throws {
        let grid = try CardGrid(rows: [[0, 1, nil, 3], [-2, 4, 5, 6], [12, 8, 9, 10]], removedColumns: [2])
        let data = try JSONEncoder().encode(grid)
        #expect(try JSONDecoder().decode(CardGrid.self, from: data) == grid)
    }

    @Test("Codable : valeur hors plage ou forme invalide rejetée au décodage")
    func decodingRejectsCorruptedData() {
        let column = #"{"top":1,"middle":2,"bottom":3,"isMarkedRemoved":false}"#
        let corruptedValue = #"{"columns":[{"top":13,"middle":2,"bottom":3,"isMarkedRemoved":false},"#
            + [column, column, column].joined(separator: ",") + "]}"
        let tooFewColumns = #"{"columns":["# + [column, column, column].joined(separator: ",") + "]}"

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CardGrid.self, from: Data(corruptedValue.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CardGrid.self, from: Data(tooFewColumns.utf8))
        }
    }
}
