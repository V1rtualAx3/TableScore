import Foundation
import Testing
import TableScoreKit

@Suite("Brouillon de saisie (§4.4, §10 n° 10)")
struct RoundDraftTests {

    private let players = Fx.players(3)

    @Test("Brouillon neuf : rien n'est soumis, aucun score implicite")
    func newDraftCannotSubmit() {
        let draft = RoundDraft(index: 1, participants: players)
        #expect(!draft.canSubmit)
        #expect(draft.missingScoreParticipantIDs == [Fx.alice, Fx.bob, Fx.chloe])
        #expect(draft.entry(for: Fx.alice)?.rawScore == nil)
        #expect(draft.closingParticipantID == nil)
    }

    @Test("§10 n° 10 : joueur sans score ⇒ soumission impossible")
    func missingScoreBlocksSubmission() {
        var draft = RoundDraft(index: 1, participants: players)
        draft.setPoints(4, for: Fx.alice)
        draft.setPoints(0, for: Fx.bob)
        draft.closingParticipantID = Fx.alice
        #expect(!draft.canSubmit)
        #expect(draft.missingScoreParticipantIDs == [Fx.chloe])
        #expect(throws: ValidationError.missingScore(participantID: Fx.chloe)) {
            try draft.makeRoundInput()
        }
    }

    @Test("Aucun clôturant ⇒ soumission impossible")
    func missingCloserBlocksSubmission() {
        var draft = RoundDraft(index: 1, participants: players)
        for player in players { draft.setPoints(1, for: player.id) }
        #expect(!draft.canSubmit)
        #expect(throws: ValidationError.missingClosingParticipant) {
            try draft.makeRoundInput()
        }
    }

    @Test("Clôturant étranger ⇒ soumission impossible")
    func foreignCloserBlocksSubmission() {
        var draft = RoundDraft(index: 1, participants: players)
        for player in players { draft.setPoints(1, for: player.id) }
        draft.closingParticipantID = pid(42)
        #expect(!draft.canSubmit)
    }

    @Test("Un seul clôturant : changer de clôturant remplace le précédent ; 0 reste 0")
    func singleCloserAndZero() throws {
        var draft = RoundDraft(index: 1, participants: players)
        draft.setPoints(-3, for: Fx.alice)
        draft.setPoints(0, for: Fx.bob)
        draft.setPoints(12, for: Fx.chloe)
        draft.closingParticipantID = Fx.alice
        draft.closingParticipantID = Fx.bob
        #expect(draft.canSubmit)

        let round = try draft.makeRoundInput()
        #expect(round.id == draft.roundID)
        #expect(round.closingParticipantID == Fx.bob)
        #expect(round.entries.map(\.participantID) == [Fx.alice, Fx.bob, Fx.chloe])
        #expect(round.entry(for: Fx.bob)?.rawScore == 0)

        let scoring = try ScoreEngine.scoreRound(round, participants: players, rules: .classic)
        #expect(scoring.verdict == .zeroNeverDoubled)
    }

    @Test("Participant inconnu ignoré et signalé")
    func unknownParticipantUpdate() {
        var draft = RoundDraft(index: 1, participants: players)
        let accepted = draft.setPoints(3, for: pid(42))
        #expect(!accepted)
        #expect(draft.entry(for: pid(42)) == nil)
    }

    @Test("§10 n° 10 : double soumission du même brouillon détectée")
    func doubleSubmissionDetected() throws {
        var draft = RoundDraft(index: 1, participants: players)
        for player in players { draft.setPoints(2, for: player.id) }
        draft.closingParticipantID = Fx.chloe

        let first = try draft.makeRoundInput()
        _ = try ScoreEngine.computeAppending(first, to: [], participants: players, rules: .classic)
        let stored = [first]

        let second = try draft.makeRoundInput()
        #expect(ScoreEngine.containsRound(id: second.id, in: stored))
        #expect(throws: ValidationError.duplicateRoundID(second.id)) {
            try ScoreEngine.computeAppending(second, to: stored, participants: players, rules: .classic)
        }
    }

    @Test("Bascule Points ↔ Cartes sans perte des données")
    func switchingModesKeepsData() throws {
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        draft.setPoints(12, for: Fx.alice)
        draft.setPoints(20, for: Fx.bob)
        draft.closingParticipantID = Fx.alice

        draft.updateEntry(for: Fx.alice) { $0.inputMethod = .cards }
        #expect(draft.entry(for: Fx.alice)?.rawScore == nil) // grille vide
        #expect(!draft.canSubmit)

        draft.updateEntry(for: Fx.alice) { $0.inputMethod = .points }
        #expect(draft.entry(for: Fx.alice)?.rawScore == 12)
        #expect(draft.canSubmit)
    }

    @Test("Saisie cartes complète ⇒ entrée « cartes » avec grille")
    func cardsEntryFromDraft() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]])
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        draft.updateEntry(for: Fx.alice) { entry in
            entry.inputMethod = .cards
            entry.cardGrid = grid
        }
        draft.setPoints(50, for: Fx.bob)
        draft.closingParticipantID = Fx.alice

        let round = try draft.makeRoundInput()
        let aliceEntry = try #require(round.entry(for: Fx.alice))
        #expect(aliceEntry.rawScore == 48)
        #expect(aliceEntry.inputMethod == .cards)
        #expect(aliceEntry.cardGrid == grid)
    }

    @Test("Saisie cartes incomplète ⇒ soumission impossible")
    func incompleteCardsBlockSubmission() throws {
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        let partial = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, nil]])
        draft.updateEntry(for: Fx.alice) { entry in
            entry.inputMethod = .cards
            entry.cardGrid = partial
        }
        draft.setPoints(5, for: Fx.bob)
        draft.closingParticipantID = Fx.bob
        #expect(throws: ValidationError.incompleteCardGrid(participantID: Fx.alice)) {
            try draft.makeRoundInput()
        }
    }

    @Test("Brouillon de correction : reconstruit fidèlement la manche existante")
    func editingDraftRoundTrip() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]])
        let aliceEntry = try RoundEntry.cards(Fx.alice, grid: grid)
        let original = RoundInput(index: 4, closingParticipantID: Fx.bob, entries: [
            aliceEntry,
            .points(Fx.bob, rawScore: -1),
            .points(Fx.chloe, rawScore: 0),
        ])
        let draft = RoundDraft(editing: original, participants: players)
        #expect(draft.roundID == original.id)
        #expect(draft.index == 4)
        #expect(try draft.makeRoundInput() == original)
    }

    // MARK: Bascule Points ↔ Cartes (arbitrage)

    private static let fullGrid: CardGrid = {
        // Total 48 (colonne 7/7/7 retirée) ; construction sans échec possible.
        var grid = CardGrid()
        let rows: [[Int]] = [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]]
        for (row, values) in rows.enumerated() {
            for (column, value) in values.enumerated() {
                try? grid.setCard(value, column: column, row: row)
            }
        }
        return grid
    }()

    @Test("Cartes → points, grille complète, points vides ⇒ pré-rempli avec le total")
    func cardsToPointsPrefillsEmptyPoints() throws {
        #expect(Self.fullGrid.evaluate().rawScore == 48)
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        draft.setInputMethod(.cards, for: Fx.alice)
        draft.updateEntry(for: Fx.alice) { $0.cardGrid = Self.fullGrid }
        #expect(draft.entry(for: Fx.alice)?.points == nil)

        draft.setInputMethod(.points, for: Fx.alice)
        let entry = try #require(draft.entry(for: Fx.alice))
        #expect(entry.points == 48)
        #expect(entry.isPointsDerivedFromGrid)
        #expect(entry.cardGrid == Self.fullGrid) // grille conservée
    }

    @Test("Cartes → points : une saisie manuelle n'est jamais écrasée")
    func manualPointsAreNeverOverwritten() throws {
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        draft.setPoints(30, for: Fx.alice)
        draft.setInputMethod(.cards, for: Fx.alice)
        draft.updateEntry(for: Fx.alice) { $0.cardGrid = Self.fullGrid }
        #expect(draft.entry(for: Fx.alice)?.rawScore == 48)

        draft.setInputMethod(.points, for: Fx.alice)
        let entry = try #require(draft.entry(for: Fx.alice))
        #expect(entry.points == 30)
        #expect(!entry.isPointsDerivedFromGrid)
    }

    @Test("Cartes → points : un score issu de la grille suit les corrections de la grille")
    func derivedPointsFollowGrid() throws {
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        draft.setInputMethod(.cards, for: Fx.alice)
        draft.updateEntry(for: Fx.alice) { $0.cardGrid = Self.fullGrid }
        draft.setInputMethod(.points, for: Fx.alice)
        #expect(draft.entry(for: Fx.alice)?.points == 48)

        draft.setInputMethod(.cards, for: Fx.alice)
        try draft.setCard(12, column: 3, row: 2, for: Fx.alice) // 10 → 12
        draft.setInputMethod(.points, for: Fx.alice)
        #expect(draft.entry(for: Fx.alice)?.points == 50)

        // Une saisie manuelle ultérieure reprend la main.
        draft.setPoints(7, for: Fx.alice)
        #expect(draft.entry(for: Fx.alice)?.isPointsDerivedFromGrid == false)
    }

    @Test("Cartes → points avec grille incomplète ⇒ champ points inchangé")
    func incompleteGridDoesNotPrefill() throws {
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        draft.setInputMethod(.cards, for: Fx.alice)
        try draft.setCard(5, column: 0, row: 0, for: Fx.alice)
        draft.setInputMethod(.points, for: Fx.alice)
        #expect(draft.entry(for: Fx.alice)?.points == nil)
        #expect(draft.entry(for: Fx.alice)?.cardGrid.columns[0][0] == 5)
    }

    @Test("Symétrie brouillon neuf / brouillon de correction")
    func newAndEditingDraftsBehaveAlike() throws {
        var fresh = RoundDraft(index: 1, participants: Fx.players(2))
        fresh.setInputMethod(.cards, for: Fx.alice)
        fresh.updateEntry(for: Fx.alice) { $0.cardGrid = Self.fullGrid }
        fresh.setPoints(9, for: Fx.bob)
        fresh.closingParticipantID = Fx.bob
        let round = try fresh.makeRoundInput()

        var edited = RoundDraft(editing: round, participants: Fx.players(2))
        let editedEntry = try #require(edited.entry(for: Fx.alice))
        #expect(editedEntry.inputMethod == .cards)
        #expect(editedEntry.points == 48)
        #expect(editedEntry.isPointsDerivedFromGrid)

        fresh.setInputMethod(.points, for: Fx.alice)
        edited.setInputMethod(.points, for: Fx.alice)
        #expect(edited.entry(for: Fx.alice) == fresh.entry(for: Fx.alice))

        // Après correction de la grille, les deux brouillons suivent la même règle.
        for index in [0, 1] {
            var draft = index == 0 ? fresh : edited
            draft.setInputMethod(.cards, for: Fx.alice)
            try draft.setCard(-1, column: 1, row: 0, for: Fx.alice) // 1 → −1
            draft.setInputMethod(.points, for: Fx.alice)
            #expect(draft.entry(for: Fx.alice)?.points == 46)
        }
    }

    @Test("Helpers de grille : participant inconnu, valeur ou position invalide refusés")
    func gridHelpers() throws {
        var draft = RoundDraft(index: 1, participants: Fx.players(2))
        try draft.setCard(0, column: 2, row: 1, for: Fx.bob)
        try draft.setColumnRemoved(true, column: 3, for: Fx.bob)
        let grid = try #require(draft.entry(for: Fx.bob)?.cardGrid)
        #expect(grid.columns[2][1] == 0)
        #expect(grid.columns[3].isMarkedRemoved)

        #expect(throws: ValidationError.unknownParticipant(pid(42))) {
            try draft.setCard(1, column: 0, row: 0, for: pid(42))
        }
        #expect(throws: ValidationError.unknownParticipant(pid(42))) {
            try draft.setColumnRemoved(true, column: 0, for: pid(42))
        }
        #expect(throws: ValidationError.cardValueOutOfRange(13)) {
            try draft.setCard(13, column: 0, row: 0, for: Fx.bob)
        }
        #expect(throws: ValidationError.cardPositionOutOfRange(column: 9, row: 0)) {
            try draft.setColumnRemoved(true, column: 9, for: Fx.bob)
        }
    }

    // MARK: Analyse du texte saisi (arbitrage)

    @Test("Analyse du texte saisi", arguments: [
        ("", ParsedScore.empty),
        ("   ", ParsedScore.empty),
        ("\u{00A0}\u{00A0}", ParsedScore.empty),
        ("0", ParsedScore.value(0)),
        ("-0", ParsedScore.value(0)),
        ("7", ParsedScore.value(7)),
        (" 12 ", ParsedScore.value(12)),
        ("\u{00A0}12\u{00A0}", ParsedScore.value(12)),
        ("-5", ParsedScore.value(-5)),
        ("\u{2212}5", ParsedScore.value(-5)),
        ("\u{2013}5", ParsedScore.value(-5)),
        ("\u{FF0D}5", ParsedScore.value(-5)),
        ("+3", ParsedScore.value(3)),
        ("\u{2212} 5", ParsedScore.value(-5)),
        ("- 5", ParsedScore.value(-5)),
        ("-\u{00A0}5", ParsedScore.value(-5)),
        ("+ 3", ParsedScore.value(3)),
        (" \u{2013} 12 ", ParsedScore.value(-12)),
        ("-9223372036854775808", ParsedScore.value(Int.min)),
        ("9223372036854775807", ParsedScore.value(Int.max)),
        ("12a", ParsedScore.invalid),
        ("--3", ParsedScore.invalid),
        ("- -3", ParsedScore.invalid),
        ("+-3", ParsedScore.invalid),
        ("1.5", ParsedScore.invalid),
        ("1 2", ParsedScore.invalid),
        ("1\u{00A0}2", ParsedScore.invalid),
        ("5-", ParsedScore.invalid),
        ("-", ParsedScore.invalid),
        ("\u{2212}", ParsedScore.invalid),
        ("\u{0663}", ParsedScore.invalid),
        ("\u{FF15}", ParsedScore.invalid),
        ("9223372036854775808", ParsedScore.invalid),
        ("-9223372036854775809", ParsedScore.invalid),
        ("99999999999999999999", ParsedScore.invalid),
    ])
    func parseScore(text: String, expected: ParsedScore) {
        #expect(RoundDraft.parseScore(text) == expected)
    }
}
