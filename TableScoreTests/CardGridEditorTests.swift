import Testing
import TableScoreKit
@testable import TableScore

/// Mode cartes (Lot 3, L3-A) : présentation pure de la grille (`CardGridPresentation`).
/// Règles vérifiées à travers l'écran : cahier §3.1 (colonnes verticales uniquement) et §3.3.
@Suite("Grille de saisie par cartes")
struct CardGridEditorTests {
    private static let nbsp = "\u{00A0}"

    /// Grille de 3 rangées (haut → bas) × 4 colonnes.
    private static func grid(_ rows: [[Int?]], removed: Set<Int> = []) throws -> CardGrid {
        try CardGrid(rows: rows, removedColumns: removed)
    }

    private static func presentation(_ grid: CardGrid, name: String = "Alice", position: Int = 0) -> CardGridPresentation {
        CardGridPresentation(grid: grid, playerName: name, position: position)
    }

    // MARK: Triplets identiques

    @Test("Trois 7 dans une colonne : colonne non comptée, message affiché, valeurs conservées")
    func identicalSevensAreNotCounted() throws {
        let sut = Self.presentation(try Self.grid([
            [7, 1, 2, 3],
            [7, 1, 2, 4],
            [7, 2, 2, 5]
        ]))
        let column = sut.columns[0]
        #expect(column.status == .identicalCards(value: 7))
        #expect(column.contribution == 0)
        #expect(column.subtotalText == "0")
        #expect(column.isExcluded)
        #expect(!column.isMarkedRemoved)
        #expect(column.statusMessage == "3 cartes identiques\(Self.nbsp): colonne non comptée")
        #expect(column.cells.map(\.value) == [7, 7, 7])
        #expect(column.cells.map(\.displayText) == ["7", "7", "7"])
        #expect(column.cells.allSatisfy { $0.isExcluded && $0.isEditable })
        // Colonne 3 (2/2/2) : aussi un triplet ; colonnes 2 et 4 comptées.
        #expect(sut.columns[2].status == .identicalCards(value: 2))
        #expect(sut.columns[1].status == .complete(sum: 4))
        #expect(sut.columns[3].status == .complete(sum: 12))
        #expect(sut.rawScore == 16)
        #expect(sut.statusMessages == [
            "Colonne 1\(Self.nbsp)— 3 cartes identiques\(Self.nbsp): colonne non comptée",
            "Colonne 3\(Self.nbsp)— 3 cartes identiques\(Self.nbsp): colonne non comptée"
        ])
    }

    @Test("Trois −2 dans une colonne : retirée aussi (le retrait ne dépend pas du signe)")
    func identicalNegativeColumnIsNotCounted() throws {
        let sut = Self.presentation(try Self.grid([
            [-2, 5, 0, 1],
            [-2, 5, 0, 1],
            [-2, 6, 1, 1]
        ]))
        #expect(sut.columns[0].status == .identicalCards(value: -2))
        #expect(sut.columns[0].contribution == 0)
        #expect(sut.columns[0].statusMessage == CardGridPresentation.identicalCardsMessage)
        #expect(sut.columns[0].cells.map(\.displayText) == ["−2", "−2", "−2"])
        #expect(sut.columns[3].status == .identicalCards(value: 1))
        // −2 × 3 retirés : 16 + 1, et non 16 + 1 − 6.
        #expect(sut.rawScore == 17)
        #expect(sut.totalText == "17")
    }

    @Test("Ligne horizontale identique 5/5/5/5 : jamais retirée")
    func horizontalLineIsNeverRemoved() throws {
        let sut = Self.presentation(try Self.grid([
            [5, 5, 5, 5],
            [1, 2, 3, 4],
            [0, -1, 6, 12]
        ]))
        #expect(sut.columns.allSatisfy { !$0.isExcluded })
        #expect(sut.columns.map(\.status) == [
            .complete(sum: 6), .complete(sum: 6), .complete(sum: 14), .complete(sum: 21)
        ])
        #expect(sut.rawScore == 47)
        #expect(sut.statusMessages.isEmpty)
    }

    // MARK: Colonne retirée manuellement

    @Test("Colonne marquée retirée : compte 0, valeurs conservées, aucun second retrait")
    func markedRemovedColumnCountsZeroAndKeepsValues() throws {
        var grid = try Self.grid([
            [9, 3, 4, 2],
            [8, 3, 4, 2],
            [nil, 3, 5, 2]
        ])
        try grid.setColumnRemoved(true, column: 0)
        var sut = Self.presentation(grid)
        let removed = sut.columns[0]
        #expect(removed.status == .markedRemoved)
        #expect(removed.isMarkedRemoved)
        #expect(removed.contribution == 0)
        #expect(removed.shortStatus == "Retirée")
        // Valeurs (y compris la case vide) conservées, estompées, non modifiables.
        #expect(removed.cells.map(\.value) == [9, 8, nil])
        #expect(removed.cells.allSatisfy { $0.isExcluded && !$0.isEditable })
        // La case vide d'une colonne retirée n'est plus exigée.
        #expect(sut.missingCardCount == 0)
        // Colonnes 2 (3/3/3) et 4 (2/2/2) : triplets automatiques, une seule fois chacun ;
        // colonne 3 comptée. Total = 13 (aucune colonne retirée deux fois, aucune soustraction).
        #expect(sut.columns[1].status == .identicalCards(value: 3))
        #expect(sut.columns[3].status == .identicalCards(value: 2))
        #expect(sut.rawScore == 13)

        // Re-basculer restaure les valeurs : la colonne redevient incomplète (case vide).
        try grid.setColumnRemoved(false, column: 0)
        sut = Self.presentation(grid)
        #expect(sut.columns[0].status == .incomplete(enteredSum: 17, missingCount: 1))
        #expect(sut.columns[0].cells.map(\.value) == [9, 8, nil])
        #expect(sut.rawScore == nil)
    }

    @Test("Triplet identique marqué retiré : un seul retrait (compte 0, pas −valeur)")
    func identicalAndMarkedRemovedIsRemovedOnce() throws {
        let grid = try Self.grid([
            [-2, 1, 1, 1],
            [-2, 2, 2, 2],
            [-2, 3, 3, 4]
        ], removed: [0])
        let sut = Self.presentation(grid)
        #expect(sut.columns[0].status == .markedRemoved)
        #expect(sut.columns[0].contribution == 0)
        #expect(sut.rawScore == 19)
    }

    // MARK: Grille incomplète

    @Test("Grille incomplète : score brut nil, total provisoire et nombre de cartes à saisir")
    func incompleteGridHasNoRawScore() throws {
        let sut = Self.presentation(try Self.grid([
            [4, nil, 1, nil],
            [nil, nil, 1, 6],
            [2, nil, 1, nil]
        ]))
        #expect(sut.rawScore == nil)
        #expect(!sut.isComplete)
        #expect(sut.missingCardCount == 6)
        #expect(sut.runningTotal == 12)
        #expect(sut.missingCardsText == "6\(Self.nbsp)cartes à saisir")
        #expect(sut.completionText == "6\(Self.nbsp)cartes à saisir")
        #expect(sut.columns[0].status == .incomplete(enteredSum: 6, missingCount: 1))
        #expect(sut.columns[1].status == .incomplete(enteredSum: 0, missingCount: 3))
        #expect(sut.columns[2].status == .identicalCards(value: 1))
    }

    @Test("Une seule carte manquante : singulier ; grille complète : plus de message")
    func missingCardsWording() throws {
        var grid = try Self.grid([
            [1, 2, 3, 4],
            [5, 6, 7, 8],
            [9, 10, 11, nil]
        ])
        #expect(Self.presentation(grid).missingCardsText == "1\(Self.nbsp)carte à saisir")
        try grid.setCard(12, column: 3, row: 2)
        let sut = Self.presentation(grid)
        #expect(sut.missingCardsText == nil)
        #expect(sut.completionText == "Grille complète")
        #expect(sut.rawScore == 78)
    }

    @Test("Zéro est une vraie valeur, distincte d'une case vide")
    func zeroIsNotEmpty() throws {
        let sut = Self.presentation(try Self.grid([
            [0, 0, 0, 0],
            [0, 0, 1, 0],
            [nil, 0, 0, 0]
        ]))
        let first = sut.columns[0].cells
        #expect(first[0].value == 0)
        #expect(first[0].displayText == "0")
        #expect(first[2].value == nil)
        #expect(first[2].displayText == "—")
        #expect(first[0].accessibilityValue == "0")
        #expect(first[2].accessibilityValue == "vide")
        #expect(sut.columns[0].status == .incomplete(enteredSum: 0, missingCount: 1))
        // 0/0/0 : triplet identique (retiré, compte 0 dans tous les cas).
        #expect(sut.columns[1].status == .identicalCards(value: 0))
        #expect(sut.columns[2].status == .complete(sum: 1))
        #expect(sut.missingCardCount == 1)
        #expect(sut.rawScore == nil)
    }

    // MARK: Accessibilité

    @Test("Libellés VoiceOver des cases, du total et des bascules")
    func voiceOverLabels() throws {
        var grid = try Self.grid([
            [nil, 7, -2, 4],
            [3, 7, 5, 4],
            [3, 7, 6, 4]
        ], removed: [3])
        var sut = Self.presentation(grid, name: "Alice", position: 2)
        let cell = sut.columns[1].cells[0]
        #expect(cell.accessibilityLabel == "Alice, colonne 2, rangée 1")
        #expect(cell.spokenDescription == "Alice, colonne 2, rangée 1, 7, colonne non comptée")
        #expect(sut.columns[0].cells[0].spokenDescription == "Alice, colonne 1, rangée 1, vide")
        #expect(sut.columns[0].cells[1].spokenDescription == "Alice, colonne 1, rangée 2, 3")
        #expect(sut.columns[2].cells[0].spokenDescription == "Alice, colonne 3, rangée 1, moins 2")
        #expect(sut.columns[3].cells[2].spokenDescription == "Alice, colonne 4, rangée 3, 4, colonne retirée")
        #expect(sut.columns[3].removeToggleAccessibilityLabel == "Colonne 4 retirée")
        #expect(sut.columns[3].subtotalAccessibilityLabel == "Colonne 4, 0 point, colonne retirée")
        #expect(sut.columns[0].subtotalAccessibilityLabel == "Colonne 1, 6 points, provisoire, 1\(Self.nbsp)carte à saisir")
        #expect(sut.totalAccessibilityLabel == "Alice, total brut 15 points, provisoire, 1\(Self.nbsp)carte à saisir")

        try grid.setCard(-2, column: 0, row: 0)
        sut = Self.presentation(grid, name: "Alice", position: 2)
        #expect(sut.totalAccessibilityLabel == "Alice, total brut 13 points")
        #expect(CardGridPresentation.spokenPoints(-1) == "moins 1 point")
        #expect(CardGridPresentation.spokenPoints(-4) == "moins 4 points")
    }

    @Test("Identifiants d'accessibilité figés (indices 0-based)")
    func accessibilityIdentifiers() throws {
        let sut = Self.presentation(CardGrid(), position: 3)
        #expect(sut.columns[1].cells[2].accessibilityIdentifier == "cards.cell.3.1.2")
        #expect(sut.columns[0].removeToggleIdentifier == "cards.removeColumn.3.0")
        #expect(sut.totalIdentifier == "cards.total.3")
        #expect(AccessibilityID.Cards.valuePicker(value: -2) == "cards.valuePicker.-2")
        #expect(AccessibilityID.Cards.valuePicker(value: 12) == "cards.valuePicker.12")
        #expect(AccessibilityID.Cards.valuePickerClear == "cards.valuePicker.clear")
        #expect(AccessibilityID.Cards.valuePickerDone == "cards.valuePicker.done")
    }

    @Test("Grille vide : 12 cases « — », 12 cartes à saisir, total 0")
    func emptyGrid() {
        let sut = Self.presentation(CardGrid())
        #expect(sut.columns.count == CardGrid.columnCount)
        #expect(sut.columns.allSatisfy { $0.cells.count == CardGrid.rowCount })
        #expect(sut.columns.flatMap(\.cells).allSatisfy { $0.displayText == "—" && $0.isEditable })
        #expect(sut.missingCardCount == 12)
        #expect(sut.runningTotal == 0)
        #expect(sut.rawScore == nil)
    }

    // MARK: Navigation de saisie

    @Test("Case suivante : ordre de lecture, cases vides seulement, colonnes retirées ignorées")
    func nextEmptyCellOrder() throws {
        typealias Position = CardGridPresentation.CellPosition
        let grid = try Self.grid([
            [1, nil, nil, 4],
            [nil, nil, 0, nil],
            [nil, 2, 3, nil]
        ], removed: [1])
        #expect(CardGridPresentation.nextEmptyCell(in: grid, after: Position(column: 0, row: 0))
            == Position(column: 2, row: 0))
        #expect(CardGridPresentation.nextEmptyCell(in: grid, after: Position(column: 2, row: 0))
            == Position(column: 0, row: 1))
        #expect(CardGridPresentation.nextEmptyCell(in: grid, after: Position(column: 3, row: 1))
            == Position(column: 0, row: 2))
        // Fin de grille : reprise au début.
        #expect(CardGridPresentation.nextEmptyCell(in: grid, after: Position(column: 3, row: 2))
            == Position(column: 2, row: 0))

        let full = try Self.grid([[1, 2, 3, 4], [1, 2, 3, 4], [1, 2, 3, nil]], removed: [3])
        #expect(CardGridPresentation.nextEmptyCell(in: full, after: Position(column: 0, row: 0)) == nil)
    }
}
