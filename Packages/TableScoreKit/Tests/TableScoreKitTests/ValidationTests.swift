import Foundation
import Testing
import TableScoreKit

@Suite("Validation des participants, règles et manches (§6.2, §10 n° 1 et 10)")
struct ValidationTests {

    // MARK: Participants

    @Test("§10 n° 1 : 2 à 8 joueurs valides", arguments: [2, 3, 8])
    func validPlayerCounts(count: Int) throws {
        let ordered = try ScoreEngine.validate(participants: Fx.players(count))
        #expect(ordered.count == count)
    }

    @Test("§10 n° 1 : 0, 1 et 9 joueurs refusés", arguments: [0, 1, 9])
    func invalidPlayerCounts(count: Int) {
        #expect(throws: ValidationError.participantCountOutOfRange(count: count)) {
            try ScoreEngine.validate(participants: Fx.players(count))
        }
    }

    @Test("Partie à 8 joueurs calculée intégralement")
    func eightPlayerGame() throws {
        let players = Fx.players(8)
        var scores: [UUID: Int] = [:]
        for (offset, player) in players.enumerated() { scores[player.id] = offset - 2 }
        let game = try ScoreEngine.computeGame(
            participants: players,
            rounds: [Fx.round(1, closer: Fx.alice, scores)],
            rules: .classic
        )
        // Alice −2, Bob −1 : Alice est seule au plus petit score.
        #expect(game.rounds[0].scoring.verdict == .negativeNeverDoubled)
        #expect(game.totals.count == 8)
        #expect(game.standings.first?.participantID == Fx.alice)
    }

    @Test("Nom vide ou composé d'espaces refusé")
    func emptyNameRejected() {
        var players = Fx.players(3)
        players[1].displayName = "  \n "
        #expect(throws: ValidationError.emptyParticipantName(participantID: Fx.bob)) {
            try ScoreEngine.validate(participants: players)
        }
    }

    @Test("Identifiants dupliqués refusés")
    func duplicateIDsRejected() {
        let players = [
            Participant(id: Fx.alice, displayName: "Alice", displayOrder: 0),
            Participant(id: Fx.alice, displayName: "Alice bis", displayOrder: 1),
        ]
        #expect(throws: ValidationError.duplicateParticipantID(Fx.alice)) {
            try ScoreEngine.validate(participants: players)
        }
    }

    @Test("Ordres d'affichage dupliqués refusés")
    func duplicateDisplayOrderRejected() {
        let players = [
            Participant(id: Fx.alice, displayName: "Alice", displayOrder: 0),
            Participant(id: Fx.bob, displayName: "Bob", displayOrder: 0),
        ]
        #expect(throws: ValidationError.duplicateDisplayOrder(0)) {
            try ScoreEngine.validate(participants: players)
        }
    }

    @Test("Ordre d'affichage modifiable sans effet sur les identifiants")
    func displayOrderSorting() throws {
        let players = [
            Participant(id: Fx.alice, displayName: "Alice", displayOrder: 5),
            Participant(id: Fx.bob, displayName: "Bob", displayOrder: -1),
        ]
        let ordered = try ScoreEngine.validate(participants: players)
        #expect(ordered.map(\.id) == [Fx.bob, Fx.alice])
    }

    @Test("Prénoms identiques autorisés (identités distinctes)")
    func homonymsAllowed() throws {
        let players = [
            Participant(id: Fx.alice, displayName: "Sam", displayOrder: 0),
            Participant(id: Fx.bob, displayName: "Sam", displayOrder: 1),
        ]
        #expect(try ScoreEngine.validate(participants: players).count == 2)
    }

    // MARK: Règles

    @Test("Seuils valides", arguments: [1, 100, 1_000])
    func validTargetScores(target: Int) throws {
        try ScoreEngine.validate(rules: GameRules(targetScore: target))
    }

    @Test("Seuils invalides refusés", arguments: [0, -100, 1_001, Int.max])
    func invalidTargetScores(target: Int) {
        #expect(throws: ValidationError.invalidTargetScore(target)) {
            try ScoreEngine.validate(rules: GameRules(targetScore: target))
        }
    }

    // MARK: Entrées de manche

    private func scoreRound(_ round: RoundInput, players: Int = 3) throws -> RoundScoring {
        try ScoreEngine.scoreRound(round, participants: Fx.players(players), rules: .classic)
    }

    @Test("§10 n° 10 : joueur sans score refusé")
    func missingEntryRejected() {
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 4])
        #expect(throws: ValidationError.missingEntry(participantID: Fx.chloe)) {
            try scoreRound(round)
        }
    }

    @Test("Participant étranger refusé")
    func foreignParticipantRejected() {
        let stranger = pid(42)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 4, Fx.chloe: 5, stranger: 1])
        #expect(throws: ValidationError.unknownParticipant(stranger)) {
            try scoreRound(round)
        }
    }

    @Test("Deux entrées pour un même participant refusées")
    func duplicateEntryRejected() {
        let round = RoundInput(index: 1, closingParticipantID: Fx.alice, entries: [
            .points(Fx.alice, rawScore: 3),
            .points(Fx.bob, rawScore: 4),
            .points(Fx.bob, rawScore: 5),
        ])
        #expect(throws: ValidationError.duplicateEntry(participantID: Fx.bob)) {
            try scoreRound(round, players: 2)
        }
    }

    @Test("Clôturant non membre refusé")
    func closerNotMemberRejected() {
        let stranger = pid(42)
        let round = Fx.round(1, closer: stranger, [Fx.alice: 3, Fx.bob: 4])
        #expect(throws: ValidationError.closingParticipantNotInGame(stranger)) {
            try scoreRound(round, players: 2)
        }
    }

    @Test("Saisie cartes incohérente avec le score brut refusée")
    func cardGridMismatchRejected() throws {
        let grid = try CardGrid(rows: [[1, 2, 3, 4], [1, 2, 3, 5], [0, 0, 0, 0]])
        let round = RoundInput(index: 1, closingParticipantID: Fx.alice, entries: [
            RoundEntry(participantID: Fx.alice, rawScore: 99, source: .cards(grid)),
            .points(Fx.bob, rawScore: 4),
        ])
        #expect(throws: ValidationError.cardGridScoreMismatch(participantID: Fx.alice, expected: 21, found: 99)) {
            try scoreRound(round, players: 2)
        }
    }

    @Test("Saisie cartes incomplète refusée")
    func incompleteCardGridRejected() throws {
        let grid = try CardGrid(rows: [[1, 2, 3, 4], [1, 2, 3, nil], [0, 0, 0, 0]])
        #expect(throws: ValidationError.incompleteCardGrid(participantID: Fx.alice)) {
            try RoundEntry.cards(Fx.alice, grid: grid)
        }
        let forged = RoundInput(index: 1, closingParticipantID: Fx.alice, entries: [
            RoundEntry(participantID: Fx.alice, rawScore: 15, source: .cards(grid)),
            .points(Fx.bob, rawScore: 4),
        ])
        #expect(throws: ValidationError.incompleteCardGrid(participantID: Fx.alice)) {
            try scoreRound(forged, players: 2)
        }
    }

    @Test("Saisie points : aucune colonne soustraite une seconde fois")
    func pointsEntryIsTakenAsIs() throws {
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 48, Fx.bob: 50])
        let result = try scoreRound(round, players: 2)
        #expect(result.score(for: Fx.alice)?.rawScore == 48)
        #expect(result.closingEffectiveScore == 48)
    }
}
