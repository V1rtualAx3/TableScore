import Foundation
import Testing
import TableScoreKit

@Suite("Historique, cumuls et fin de partie (§10 n° 7–12)")
struct GameHistoryTests {

    private func compute(_ rounds: [RoundInput], players: Int = 2, rules: GameRules = .classic) throws -> GameComputation {
        try ScoreEngine.computeGame(participants: Fx.players(players), rounds: rounds, rules: rules)
    }

    @Test("Partie sans manche : en cours, tous à 0 et co-leaders")
    func emptyGame() throws {
        let game = try compute([])
        #expect(game.status == .inProgress)
        #expect(game.totals == [Fx.alice: 0, Fx.bob: 0])
        #expect(game.standings.map(\.rank) == [1, 1])
        #expect(game.nextRoundIndex == 1)
        #expect(game.acceptsNewRound)
    }

    @Test("§10 n° 7 : score négatif réduit le cumul, cumuls déjà négatifs")
    func negativeTotals() throws {
        let game = try compute([
            Fx.round(1, closer: Fx.alice, [Fx.alice: -5, Fx.bob: 3]),
            Fx.round(2, closer: Fx.bob, [Fx.alice: -4, Fx.bob: 2]), // Bob doublé : 4
            Fx.round(3, closer: Fx.alice, [Fx.alice: -3, Fx.bob: -6]), // négatif : non doublé
        ])
        #expect(game.rounds.map(\.totalsAfterRound) == [
            [Fx.alice: -5, Fx.bob: 3],
            [Fx.alice: -9, Fx.bob: 7],
            [Fx.alice: -12, Fx.bob: 1],
        ])
        #expect(game.standings.map(\.participantID) == [Fx.alice, Fx.bob])
        #expect(game.status == .inProgress)
    }

    @Test("§10 n° 8 : 99 → 101 après une manche ⇒ fin, plus petit cumul gagnant")
    func ninetyNineToHundredOneEnds() throws {
        let game = try compute([
            Fx.round(1, closer: Fx.bob, [Fx.alice: 99, Fx.bob: 0]),
            Fx.round(2, closer: Fx.bob, [Fx.alice: 2, Fx.bob: 0]),
        ])
        #expect(game.rounds[0].reachesTargetScore == false)
        #expect(game.totals[Fx.alice] == 101)
        #expect(game.status == .finished(roundIndex: 2, winnerIDs: [Fx.bob]))
        #expect(game.inconsistency == nil)
        #expect(!game.acceptsNewRound)
        // Sans incohérence, l'état de fin coïncide avec l'état courant.
        #expect(game.totalsAtEnd == game.totals)
        #expect(game.standingsAtEnd == game.standings)
    }

    @Test("§10 n° 8 : 99 → 99 ⇒ la partie continue")
    func ninetyNineStaysContinues() throws {
        let game = try compute([
            Fx.round(1, closer: Fx.bob, [Fx.alice: 99, Fx.bob: 0]),
            Fx.round(2, closer: Fx.bob, [Fx.alice: 0, Fx.bob: 0]),
        ])
        #expect(game.totals[Fx.alice] == 99)
        #expect(game.status == .inProgress)
        #expect(game.acceptsNewRound)
        #expect(game.totalsAtEnd == nil)
        #expect(game.standingsAtEnd == nil)
    }

    @Test("Exactement 100 ⇒ fin de partie")
    func exactlyHundredEnds() throws {
        let game = try compute([Fx.round(1, closer: Fx.bob, [Fx.alice: 100, Fx.bob: 1])])
        #expect(game.status == .finished(roundIndex: 1, winnerIDs: [Fx.bob]))
    }

    @Test("Le doublement peut déclencher la fin : 55 doublé ⇒ 110")
    func doublingTriggersEnd() throws {
        let game = try compute([Fx.round(1, closer: Fx.alice, [Fx.alice: 55, Fx.bob: 50])])
        #expect(game.totals[Fx.alice] == 110)
        #expect(game.status == .finished(roundIndex: 1, winnerIDs: [Fx.bob]))
    }

    @Test("§10 n° 8 : plusieurs joueurs > 100 simultanément ⇒ gagnant au plus petit cumul")
    func severalAboveTarget() throws {
        let game = try compute([
            Fx.round(1, closer: Fx.alice, [Fx.alice: 95, Fx.bob: 98, Fx.chloe: 99]),
            Fx.round(2, closer: Fx.bob, [Fx.alice: 10, Fx.bob: 3, Fx.chloe: 5]),
        ], players: 3)
        #expect(game.totals == [Fx.alice: 105, Fx.bob: 101, Fx.chloe: 104])
        #expect(game.status == .finished(roundIndex: 2, winnerIDs: [Fx.bob]))
        #expect(game.standings.map(\.participantID) == [Fx.bob, Fx.chloe, Fx.alice])
    }

    @Test("Le premier à atteindre le seuil n'est pas le gagnant")
    func firstToReachIsNotWinner() throws {
        let game = try compute([
            Fx.round(1, closer: Fx.chloe, [Fx.alice: 101, Fx.bob: 40, Fx.chloe: 20]),
        ], players: 3)
        #expect(game.status == .finished(roundIndex: 1, winnerIDs: [Fx.chloe]))
    }

    @Test("§10 n° 9 : égalité au minimum ⇒ co-vainqueurs, pas de départage")
    func coWinners() throws {
        let game = try compute([
            Fx.round(1, closer: Fx.chloe, [Fx.alice: 50, Fx.bob: 50, Fx.chloe: 60]), // Chloé doublée : 120
        ], players: 3)
        #expect(game.status == .finished(roundIndex: 1, winnerIDs: [Fx.alice, Fx.bob]))
        #expect(game.standings.map(\.rank) == [1, 1, 3])
        #expect(game.standings.filter(\.isLeader).map(\.participantID) == [Fx.alice, Fx.bob])
    }

    @Test("§10 n° 11 : correction du brut puis du clôturant d'une ancienne manche ⇒ recalcul complet")
    func correctingOldRoundRecomputesEverything() throws {
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 5, Fx.bob: 8])
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: 4, Fx.bob: 6])
        let r3 = Fx.round(3, closer: Fx.alice, [Fx.alice: 2, Fx.bob: 3])

        let original = try compute([r1, r2, r3])
        #expect(original.rounds.map(\.scoring.closingEffectiveScore) == [5, 12, 2])
        #expect(original.rounds.map(\.totalsAfterRound) == [
            [Fx.alice: 5, Fx.bob: 8],
            [Fx.alice: 9, Fx.bob: 20],
            [Fx.alice: 11, Fx.bob: 23],
        ])

        // Bob avait en réalité 5 en manche 1 : égalité ⇒ Alice doublée.
        var corrected1 = r1
        corrected1.setEntry(.points(Fx.bob, rawScore: 5))
        let afterRaw = try compute([corrected1, r2, r3])
        #expect(afterRaw.rounds.map(\.scoring.closingEffectiveScore) == [10, 12, 2])
        #expect(afterRaw.rounds.map(\.totalsAfterRound) == [
            [Fx.alice: 10, Fx.bob: 5],
            [Fx.alice: 14, Fx.bob: 17],
            [Fx.alice: 16, Fx.bob: 20],
        ])

        // C'est Alice qui avait clôturé la manche 2 : seule plus petite ⇒ plus de doublement de Bob.
        var corrected2 = r2
        corrected2.closingParticipantID = Fx.alice
        let afterCloser = try compute([corrected1, corrected2, r3])
        #expect(afterCloser.rounds[1].scoring.verdict == .soleLowest)
        #expect(afterCloser.rounds.map(\.totalsAfterRound) == [
            [Fx.alice: 10, Fx.bob: 5],
            [Fx.alice: 14, Fx.bob: 11],
            [Fx.alice: 16, Fx.bob: 14],
        ])
    }

    @Test("§10 n° 12 : correction créant une fin antérieure ⇒ incohérence signalée, rien supprimé")
    func correctionCreatesEarlierEnd() throws {
        let r1 = Fx.round(1, closer: Fx.bob, [Fx.alice: 50, Fx.bob: 10])
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: 40, Fx.bob: 10])
        let r3 = Fx.round(3, closer: Fx.bob, [Fx.alice: 5, Fx.bob: 5])
        let before = try compute([r1, r2, r3])
        #expect(before.status == .inProgress)
        #expect(before.totals == [Fx.alice: 95, Fx.bob: 30])

        var corrected = r2
        corrected.setEntry(.points(Fx.alice, rawScore: 60))
        let after = try compute([r1, corrected, r3])

        #expect(after.rounds.count == 3)
        #expect(after.status == .finished(roundIndex: 2, winnerIDs: [Fx.bob]))
        let inconsistency = try #require(after.inconsistency)
        #expect(inconsistency.endingRoundIndex == 2)
        #expect(inconsistency.subsequentRoundIDs == [r3.id])
        #expect(after.rounds.map(\.isAfterGameEnd) == [false, false, true])
        #expect(after.totals == [Fx.alice: 115, Fx.bob: 30])
        #expect(!after.acceptsNewRound)

        // Les vainqueurs se lisent sur les cumuls de la manche de fin, pas sur les cumuls courants.
        let totalsAtEnd = try #require(after.totalsAtEnd)
        let standingsAtEnd = try #require(after.standingsAtEnd)
        #expect(totalsAtEnd == [Fx.alice: 110, Fx.bob: 20])
        #expect(totalsAtEnd == after.rounds[1].totalsAfterRound)
        #expect(standingsAtEnd.map(\.total) == [20, 110])
        let minimum = try #require(totalsAtEnd.values.min())
        let winnersFromTotals = Fx.players(2).map(\.id).filter { totalsAtEnd[$0] == minimum }
        #expect(after.status == .finished(roundIndex: 2, winnerIDs: winnersFromTotals))
        #expect(standingsAtEnd.filter(\.isLeader).map(\.participantID) == winnersFromTotals)
    }

    @Test("Résultat identique quel que soit l'ordre des entrées et des manches fournies")
    func independentOfInputOrder() throws {
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 7, Fx.bob: 7, Fx.chloe: 1])
        let r2 = Fx.round(2, closer: Fx.chloe, [Fx.alice: 3, Fx.bob: -2, Fx.chloe: 9])
        var r1Reversed = r1
        r1Reversed.entries.reverse()
        var r2Rotated = r2
        r2Rotated.entries = Array(r2.entries.dropFirst()) + [r2.entries[0]]

        let reference = try compute([r1, r2], players: 3)
        let shuffled = try compute([r2Rotated, r1Reversed], players: 3)
        // Égalité complète : manches, scores (ordre d'affichage), verdicts, cumuls, classement, statut.
        #expect(shuffled == reference)
        #expect(reference.rounds.map(\.scoring.closingEffectiveScore) == [14, 18])
        #expect(reference.totals == [Fx.alice: 17, Fx.bob: 5, Fx.chloe: 19])
    }

    @Test("Changer l'ordre d'affichage ne modifie ni identités ni cumuls, seulement l'ordre de présentation")
    func displayOrderOnlyAffectsPresentation() throws {
        let rounds = [Fx.round(1, closer: Fx.alice, [Fx.alice: 4, Fx.bob: 4, Fx.chloe: 2])]
        var reordered = Fx.players(3)
        reordered[0].displayOrder = 2
        reordered[2].displayOrder = 0

        let reference = try compute(rounds, players: 3)
        let moved = try ScoreEngine.computeGame(participants: reordered, rounds: rounds, rules: .classic)
        #expect(moved.totals == reference.totals)
        #expect(moved.rounds[0].scoring.scores.map(\.participantID) == [Fx.chloe, Fx.bob, Fx.alice])
        #expect(moved.rounds[0].scoring.verdict == .doubled(lowerParticipantIDs: [Fx.chloe], tiedParticipantIDs: [Fx.bob]))
        // Aucune égalité de cumul (Chloé 2, Bob 4, Alice 8) : le classement ne dépend que des totaux.
        #expect(moved.standings.map(\.participantID) == reference.standings.map(\.participantID))
    }

    @Test("Indices non continus refusés")
    func discontinuousIndicesRejected() {
        #expect(throws: ValidationError.roundIndexMismatch(expected: 2, found: 3)) {
            try compute([
                Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]),
                Fx.round(3, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]),
            ])
        }
        #expect(throws: ValidationError.roundIndexMismatch(expected: 1, found: 0)) {
            try compute([Fx.round(0, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])])
        }
        #expect(throws: ValidationError.roundIndexMismatch(expected: 2, found: 1)) {
            try compute([
                Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]),
                Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]),
            ])
        }
    }

    @Test("Identifiant de manche dupliqué dans l'historique refusé")
    func duplicateRoundIDRejected() {
        let id = pid(200)
        #expect(throws: ValidationError.duplicateRoundID(id)) {
            try compute([
                Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2], id: id),
                Fx.round(2, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2], id: id),
            ])
        }
    }

    @Test("Débordement du cumul ⇒ erreur contextualisée, pas de crash")
    func totalOverflow() {
        #expect(throws: ValidationError.invalidRound(index: 2, reason: .arithmeticOverflow(participantID: Fx.alice))) {
            try compute([
                Fx.round(1, closer: Fx.bob, [Fx.alice: Int.max, Fx.bob: 0]),
                Fx.round(2, closer: Fx.bob, [Fx.alice: 1, Fx.bob: 0]),
            ])
        }
        #expect(throws: ValidationError.invalidRound(index: 2, reason: .arithmeticOverflow(participantID: Fx.alice))) {
            try compute([
                Fx.round(1, closer: Fx.bob, [Fx.alice: Int.min, Fx.bob: 0]),
                Fx.round(2, closer: Fx.bob, [Fx.alice: -1, Fx.bob: 0]),
            ])
        }
    }

    @Test("Seuil personnalisé (règle maison) respecté")
    func customTarget() throws {
        let rules = GameRules(targetScore: 50)
        let game = try compute([Fx.round(1, closer: Fx.bob, [Fx.alice: 50, Fx.bob: 3])], rules: rules)
        #expect(game.status == .finished(roundIndex: 1, winnerIDs: [Fx.bob]))
    }

    @Test("Centaines de manches à 8 joueurs recalculées")
    func manyRounds() throws {
        let players = Fx.players(8)
        let rounds = (1...500).map { index in
            var scores: [UUID: Int] = [:]
            for player in players { scores[player.id] = 0 }
            return Fx.round(index, closer: players[index % players.count].id, scores)
        }
        let game = try ScoreEngine.computeGame(participants: players, rounds: rounds, rules: .classic)
        #expect(game.rounds.count == 500)
        #expect(game.status == .inProgress)
        #expect(game.nextRoundIndex == 501)
    }

    // MARK: Ajout d'une manche

    @Test("Ajout : manche suivante acceptée et cumuls à venir prévisualisés")
    func appendPreview() throws {
        let players = Fx.players(2)
        let existing = [Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 9])]
        let next = Fx.round(2, closer: Fx.bob, [Fx.alice: 4, Fx.bob: 4])
        let preview = try ScoreEngine.computeAppending(next, to: existing, participants: players, rules: .classic)
        #expect(preview.rounds.last?.scoring.verdict == .doubled(lowerParticipantIDs: [], tiedParticipantIDs: [Fx.alice]))
        #expect(preview.totals == [Fx.alice: 7, Fx.bob: 17])
    }

    @Test("§10 n° 10 : la même validation ne peut pas être enregistrée deux fois")
    func doubleSubmissionRejected() throws {
        let players = Fx.players(2)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 9])
        _ = try ScoreEngine.computeAppending(round, to: [], participants: players, rules: .classic)
        let stored = [round]
        #expect(ScoreEngine.containsRound(id: round.id, in: stored))
        #expect(throws: ValidationError.duplicateRoundID(round.id)) {
            try ScoreEngine.computeAppending(round, to: stored, participants: players, rules: .classic)
        }
    }

    @Test("Ajout refusé après la fin de partie ou avec un indice incorrect")
    func appendRejections() {
        let players = Fx.players(2)
        let finished = [Fx.round(1, closer: Fx.bob, [Fx.alice: 120, Fx.bob: 0])]
        #expect(throws: ValidationError.gameAlreadyFinished(atRoundIndex: 1)) {
            try ScoreEngine.computeAppending(
                Fx.round(2, closer: Fx.bob, [Fx.alice: 1, Fx.bob: 0]),
                to: finished, participants: players, rules: .classic
            )
        }
        #expect(throws: ValidationError.roundIndexMismatch(expected: 1, found: 2)) {
            try ScoreEngine.computeAppending(
                Fx.round(2, closer: Fx.bob, [Fx.alice: 1, Fx.bob: 0]),
                to: [], participants: players, rules: .classic
            )
        }
    }

    @Test("Ajout d'une manche invalide ⇒ erreur contextualisée par l'indice")
    func appendInvalidRound() {
        let players = Fx.players(3)
        let existing = [Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 9, Fx.chloe: 4])]
        #expect(throws: ValidationError.invalidRound(index: 2, reason: .missingEntry(participantID: Fx.chloe))) {
            try ScoreEngine.computeAppending(
                Fx.round(2, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]),
                to: existing, participants: players, rules: .classic
            )
        }
        let stranger = pid(42)
        #expect(throws: ValidationError.invalidRound(index: 2, reason: .closingParticipantNotInGame(stranger))) {
            try ScoreEngine.computeAppending(
                Fx.round(2, closer: stranger, [Fx.alice: 1, Fx.bob: 2, Fx.chloe: 3]),
                to: existing, participants: players, rules: .classic
            )
        }
    }

    @Test("Historique corrompu : brut ≠ total de la grille ⇒ erreur, pas de calcul")
    func corruptedCardEntryInHistory() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]]) // total 48
        let forged = RoundInput(index: 2, closingParticipantID: Fx.bob, entries: [
            RoundEntry(participantID: Fx.alice, rawScore: 12, source: .cards(grid)),
            .points(Fx.bob, rawScore: 5),
        ])
        let rounds = [Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]), forged]
        let expected = ValidationError.invalidRound(
            index: 2,
            reason: .cardGridScoreMismatch(participantID: Fx.alice, expected: 48, found: 12)
        )
        #expect(throws: expected) {
            try compute(rounds)
        }
        #expect(expected.underlyingReason == .cardGridScoreMismatch(participantID: Fx.alice, expected: 48, found: 12))
        #expect(ValidationError.missingClosingParticipant.underlyingReason == .missingClosingParticipant)
    }

    // MARK: Correction d'une manche

    @Test("Correction via computeReplacing : recalcul intégral, incohérence signalée sans suppression")
    func replacingRecomputes() throws {
        let players = Fx.players(2)
        let r1 = Fx.round(1, closer: Fx.bob, [Fx.alice: 50, Fx.bob: 10])
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: 40, Fx.bob: 10])
        let r3 = Fx.round(3, closer: Fx.bob, [Fx.alice: 5, Fx.bob: 5])
        let rounds = [r1, r2, r3]

        var corrected = r1
        corrected.closingParticipantID = Fx.alice // Alice 50 > Bob 10 ⇒ doublée : 100
        let result = try ScoreEngine.computeReplacing(corrected, in: rounds, participants: players, rules: .classic)
        #expect(result.rounds.count == 3)
        #expect(result.rounds[0].scoring.closingEffectiveScore == 100)
        #expect(result.status == .finished(roundIndex: 1, winnerIDs: [Fx.bob]))
        #expect(result.inconsistency?.subsequentRoundIDs == [r2.id, r3.id])
        #expect(result.totalsAtEnd == [Fx.alice: 100, Fx.bob: 10])

        // Le résultat est identique à un recalcul complet de l'historique corrigé.
        let full = try ScoreEngine.computeGame(participants: players, rounds: [corrected, r2, r3], rules: .classic)
        #expect(result == full)
    }

    @Test("Correction refusée : manche inconnue, indice modifié ou entrée invalide")
    func replacingRejections() {
        let players = Fx.players(2)
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        let r2 = Fx.round(2, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])

        let unknown = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        #expect(throws: ValidationError.unknownRound(unknown.id)) {
            try ScoreEngine.computeReplacing(unknown, in: [r1, r2], participants: players, rules: .classic)
        }

        var moved = r2
        moved.index = 1
        #expect(throws: ValidationError.roundIndexMismatch(expected: 2, found: 1)) {
            try ScoreEngine.computeReplacing(moved, in: [r1, r2], participants: players, rules: .classic)
        }

        var incomplete = r2
        incomplete.entries = [.points(Fx.alice, rawScore: 1)]
        #expect(throws: ValidationError.invalidRound(index: 2, reason: .missingEntry(participantID: Fx.bob))) {
            try ScoreEngine.computeReplacing(incomplete, in: [r1, r2], participants: players, rules: .classic)
        }
    }

    @Test("Codable : aller-retour d'une manche avec grille")
    func roundInputCodable() throws {
        let grid = try CardGrid(rows: [[7, 1, 2, 3], [7, 4, 5, 6], [7, 8, 9, 10]])
        let aliceEntry = try RoundEntry.cards(Fx.alice, grid: grid)
        let round = RoundInput(index: 1, closingParticipantID: Fx.alice, entries: [
            aliceEntry,
            .points(Fx.bob, rawScore: -2),
        ])
        let decoded = try JSONDecoder().decode(RoundInput.self, from: JSONEncoder().encode(round))
        #expect(decoded == round)
    }
}
