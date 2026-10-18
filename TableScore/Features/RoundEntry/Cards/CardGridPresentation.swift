import Foundation
import TableScoreKit

/// Présentation **pure** de la grille finale d'un joueur (mode cartes, cahier §3.3).
///
/// Aucune règle de score ici : statut des colonnes, sous-totaux et total proviennent exclusivement
/// de `CardGrid.evaluate()` (Kit). Ce type ne fait que les mettre en forme (textes FR, libellés
/// VoiceOver, identifiants) ; il est construit à chaque rendu et testé sans interface.
///
/// Indices : `column` et `row` sont **0-based** (comme `CardGrid`) ; les textes affichés à
/// l'utilisateur sont **1-based** (« colonne 2, rangée 1 » = `column: 1, row: 0`, rangée 1 = haut).
///
/// Typographie : U+00A0 (insécable) avant « : » et entre un nombre et son unité.
struct CardGridPresentation: Equatable, Sendable {
    /// Espace insécable.
    static let nbsp = "\u{00A0}"
    /// Texte d'une case vide (jamais « 0 » : zéro est une vraie valeur).
    static let emptyCellText = "—"
    /// Message du cahier §3.3, affiché pour un triplet identique (y compris négatif).
    static let identicalCardsMessage = "3 cartes identiques\(nbsp): colonne non comptée"
    /// Titre du bouton de bascule par colonne.
    static let removeColumnTitle = "Colonne retirée"

    /// Emplacement d'une carte (indices 0-based).
    struct CellPosition: Hashable, Sendable {
        let column: Int
        let row: Int
    }

    /// État d'une colonne verticale, tel que calculé par le Kit.
    enum ColumnStatus: Equatable, Sendable {
        /// Trois cartes renseignées, non identiques : la colonne compte leur somme.
        case complete(sum: Int)
        /// Au moins une carte manquante : somme provisoire des cartes saisies.
        case incomplete(enteredSum: Int, missingCount: Int)
        /// Bouton « Colonne retirée » : compte 0, valeurs conservées mais ignorées.
        case markedRemoved
        /// Trois cartes identiques saisies : retrait automatique, compte 0, valeurs conservées.
        case identicalCards(value: Int)

        init(_ outcome: ColumnOutcome) {
            switch outcome {
            case .counted(let sum): self = .complete(sum: sum)
            case .incomplete(let enteredSum, let missingCount):
                self = .incomplete(enteredSum: enteredSum, missingCount: missingCount)
            case .markedRemoved: self = .markedRemoved
            case .identicalCards(let value): self = .identicalCards(value: value)
            }
        }
    }

    struct Cell: Equatable, Sendable, Identifiable {
        let position: CellPosition
        /// `nil` = case vide (distincte de `0`).
        let value: Int?
        /// Colonne retirée ou triplet identique : case estompée (valeur conservée).
        let isExcluded: Bool
        /// Faux si la colonne est marquée retirée (re-basculer la colonne pour corriger).
        let isEditable: Bool
        /// « 7 », « −2 », « 0 » ou « — ».
        let displayText: String
        /// « Alice, colonne 2, rangée 1 ».
        let accessibilityLabel: String
        /// « 7 », « moins 2 », « vide », éventuellement suivi de l'état de la colonne.
        let accessibilityValue: String
        let accessibilityIdentifier: String

        var id: CellPosition { position }
        /// Lecture complète VoiceOver : « Alice, colonne 2, rangée 1, 7 ».
        var spokenDescription: String { "\(accessibilityLabel), \(accessibilityValue)" }
    }

    struct Column: Equatable, Sendable, Identifiable {
        /// Indice 0-based.
        let index: Int
        let status: ColumnStatus
        /// Haut → bas (toujours `CardGrid.rowCount` cases).
        let cells: [Cell]
        /// Contribution au total en direct (0 si retirée ou triplet identique).
        let contribution: Int
        /// Valeur du bouton « Colonne retirée ».
        let isMarkedRemoved: Bool
        /// « Colonne 2 ».
        let title: String
        /// Sous-total affiché (« 15 », « −3 », « 0 »).
        let subtotalText: String
        /// Libellé VoiceOver du sous-total : « Colonne 2, 15 points ».
        let subtotalAccessibilityLabel: String
        /// Étiquette courte sous le sous-total (« Retirée », « Non comptée ») ; `nil` sinon.
        let shortStatus: String?
        /// Explication complète (sous la grille) ; `nil` si la colonne compte normalement.
        let statusMessage: String?
        /// Libellé VoiceOver du bouton de bascule : « Colonne 2 retirée ».
        let removeToggleAccessibilityLabel: String
        let removeToggleIdentifier: String

        var id: Int { index }
        /// Colonne ne contribuant pas (retrait manuel ou triplet identique).
        var isExcluded: Bool {
            switch status {
            case .markedRemoved, .identicalCards: true
            case .complete, .incomplete: false
            }
        }
    }

    let playerName: String
    /// Rang 0-based du participant (convention `AccessibilityID`).
    let position: Int
    /// De gauche à droite (toujours `CardGrid.columnCount` colonnes).
    let columns: [Column]
    /// Total brut provisoire (`CardGridEvaluation.runningTotal`).
    let runningTotal: Int
    /// Score brut validable ; `nil` tant qu'une carte présente n'est pas renseignée.
    let rawScore: Int?
    let missingCardCount: Int

    init(grid: CardGrid, playerName: String, position: Int) {
        let evaluation = grid.evaluate()
        self.playerName = playerName
        self.position = position
        self.runningTotal = evaluation.runningTotal
        self.rawScore = evaluation.rawScore
        self.missingCardCount = evaluation.missingCardCount
        self.columns = zip(grid.columns, evaluation.columns).enumerated().map { index, pair in
            Self.makeColumn(
                index: index,
                column: pair.0,
                outcome: pair.1,
                playerName: playerName,
                position: position
            )
        }
    }

    // MARK: Textes de la grille

    var isComplete: Bool { rawScore != nil }

    /// « 1 carte à saisir », « 3 cartes à saisir » ; `nil` quand la grille est complète.
    var missingCardsText: String? {
        guard missingCardCount > 0 else { return nil }
        return Self.missingCardsText(missingCardCount)
    }

    /// Texte sous le total : cartes manquantes ou « Grille complète ».
    var completionText: String { missingCardsText ?? "Grille complète" }

    /// Total affiché (signe moins typographique).
    var totalText: String { ScoreFormat.display(runningTotal) }

    /// « Alice, total brut 23 points » ; si incomplet : « …, provisoire, 3 cartes à saisir ».
    var totalAccessibilityLabel: String {
        let base = "\(playerName), total brut \(Self.spokenPoints(runningTotal))"
        guard let missingCardsText else { return base }
        return "\(base), provisoire, \(missingCardsText)"
    }

    var totalIdentifier: String { AccessibilityID.Cards.total(position: position) }

    /// Explications des colonnes non comptées, de gauche à droite :
    /// « Colonne 2 — 3 cartes identiques : colonne non comptée ».
    var statusMessages: [String] {
        columns.compactMap { column in
            column.statusMessage.map { "\(column.title)\(Self.nbsp)— \($0)" }
        }
    }

    func cell(at position: CellPosition) -> Cell? {
        guard columns.indices.contains(position.column),
              columns[position.column].cells.indices.contains(position.row)
        else { return nil }
        return columns[position.column].cells[position.row]
    }

    /// En-tête du sélecteur de valeur : « Colonne 2, rangée 1 ».
    static func positionTitle(_ position: CellPosition) -> String {
        "Colonne \(position.column + 1), rangée \(position.row + 1)"
    }

    // MARK: Navigation de saisie

    /// Prochaine case vide à saisir après `position`, dans l'ordre de lecture (rangée par rangée,
    /// de gauche à droite), en reprenant au début ; les colonnes marquées retirées sont ignorées.
    /// `nil` si aucune case modifiable n'est vide (grille terminée).
    static func nextEmptyCell(in grid: CardGrid, after position: CellPosition) -> CellPosition? {
        let columnCount = CardGrid.columnCount
        let total = columnCount * CardGrid.rowCount
        let start = position.row * columnCount + position.column
        for step in 1...total {
            let linear = (start + step) % total
            let candidate = CellPosition(column: linear % columnCount, row: linear / columnCount)
            let column = grid.columns[candidate.column]
            if !column.isMarkedRemoved, column[candidate.row] == nil {
                return candidate
            }
        }
        return nil
    }

    // MARK: Formatage

    static func missingCardsText(_ count: Int) -> String {
        count == 1 ? "1\(nbsp)carte à saisir" : "\(count)\(nbsp)cartes à saisir"
    }

    /// « 23 points », « 1 point », « 0 point », « moins 2 points ».
    static func spokenPoints(_ value: Int) -> String {
        let unit = value.magnitude <= 1 ? "point" : "points"
        return "\(ScoreFormat.spoken(value)) \(unit)"
    }

    /// Valeur lue d'une carte : « 7 », « moins 2 », « vide ».
    static func spokenCardValue(_ value: Int?) -> String {
        value.map(ScoreFormat.spoken) ?? "vide"
    }

    private static func makeColumn(
        index: Int,
        column: CardColumn,
        outcome: ColumnOutcome,
        playerName: String,
        position: Int
    ) -> Column {
        let status = ColumnStatus(outcome)
        let title = "Colonne \(index + 1)"
        let isExcluded: Bool
        let cellSuffix: String?
        let shortStatus: String?
        let statusMessage: String?
        switch status {
        case .markedRemoved:
            isExcluded = true
            cellSuffix = "colonne retirée"
            shortStatus = "Retirée"
            statusMessage = "colonne retirée\(nbsp): compte 0"
        case .identicalCards:
            isExcluded = true
            cellSuffix = "colonne non comptée"
            shortStatus = "Non comptée"
            statusMessage = identicalCardsMessage
        case .complete, .incomplete:
            isExcluded = false
            cellSuffix = nil
            shortStatus = nil
            statusMessage = nil
        }

        let cells = (0..<CardGrid.rowCount).map { row in
            let value = column[row]
            let spoken = spokenCardValue(value)
            return Cell(
                position: CellPosition(column: index, row: row),
                value: value,
                isExcluded: isExcluded,
                isEditable: !column.isMarkedRemoved,
                displayText: value.map(ScoreFormat.display) ?? emptyCellText,
                accessibilityLabel: "\(playerName), colonne \(index + 1), rangée \(row + 1)",
                accessibilityValue: cellSuffix.map { "\(spoken), \($0)" } ?? spoken,
                accessibilityIdentifier: AccessibilityID.Cards.cell(position: position, column: index, row: row)
            )
        }

        let contribution = outcome.runningContribution
        let subtotalLabel: String
        switch status {
        case .incomplete(_, let missing):
            subtotalLabel = "\(title), \(spokenPoints(contribution)), provisoire, \(missingCardsText(missing))"
        case .markedRemoved, .identicalCards:
            subtotalLabel = "\(title), \(spokenPoints(contribution)), \(cellSuffix ?? "")"
        case .complete:
            subtotalLabel = "\(title), \(spokenPoints(contribution))"
        }

        return Column(
            index: index,
            status: status,
            cells: cells,
            contribution: contribution,
            isMarkedRemoved: column.isMarkedRemoved,
            title: title,
            subtotalText: ScoreFormat.display(contribution),
            subtotalAccessibilityLabel: subtotalLabel,
            shortStatus: shortStatus,
            statusMessage: statusMessage,
            removeToggleAccessibilityLabel: "\(title) retirée",
            removeToggleIdentifier: AccessibilityID.Cards.removeColumn(position: position, column: index)
        )
    }
}
