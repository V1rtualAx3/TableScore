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

    @Test("Analyse du texte saisi", arguments: [
        ("", ParsedScore.empty),
        ("   ", ParsedScore.empty),
        ("0", ParsedScore.value(0)),
        ("-0", ParsedScore.value(0)),
        ("7", ParsedScore.value(7)),
        (" 12 ", ParsedScore.value(12)),
        ("-5", ParsedScore.value(-5)),
        ("\u{2212}5", ParsedScore.value(-5)),
        ("+3", ParsedScore.value(3)),
        ("12a", ParsedScore.invalid),
        ("--3", ParsedScore.invalid),
        ("1.5", ParsedScore.invalid),
        ("1 2", ParsedScore.invalid),
        ("-", ParsedScore.invalid),
        ("\u{0663}", ParsedScore.invalid),
        ("99999999999999999999", ParsedScore.invalid),
    ])
    func parseScore(text: String, expected: ParsedScore) {
        #expect(RoundDraft.parseScore(text) == expected)
    }
}
