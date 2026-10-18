#if DEBUG
import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Extraction des vainqueurs et du classement final : lecture seule de `GameComputation`.
@Suite("Fin de partie (GameOverSummary)")
@MainActor
struct GameOverTests {
    private func summary(for seed: UITestSeed) throws -> GameOverSummary {
        let repository = InMemoryGameRepository()
        try seed.apply(to: repository)
        let game = try repository.game(id: seed.activeGameID)
        return try #require(GameOverSummary(game: game))
    }

    @Test("Égalité de fin : co-vainqueurs Bob et Chloé à 26, Alice 105")
    func coWinners() throws {
        let result = try summary(for: .tieEnd)
        #expect(result.winnerNames == ["Bob", "Chloé"])
        #expect(result.winnerTotal == 26)
        #expect(result.hasCoWinners)
        #expect(result.roundCount == 3)
        #expect(result.lines.map(\.name) == ["Bob", "Chloé", "Alice"])
        #expect(result.lines.map(\.total) == [26, 26, 105])
        #expect(result.lines.map(\.rank) == [1, 1, 3])
        #expect(result.lines.map(\.isWinner) == [true, true, false])
        #expect(result.headline == "Égalité\u{00A0}: Bob et Chloé gagnent ensemble")
        #expect(result.spokenSummary.contains("Bob et Chloé"))
    }

    @Test("Vainqueur unique : plus petit total, pas le premier à atteindre le seuil")
    func singleWinner() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.withHistory.apply(to: repository)
        let finished = try #require(
            try repository.closedGames().compactMap { listing -> SavedGame? in
                if case .readable(let game) = listing, game.isOver { return game }
                return nil
            }.first
        )
        let result = try #require(GameOverSummary(game: finished))
        #expect(result.winnerNames == ["Bob"])
        #expect(!result.hasCoWinners)
        #expect(result.headline == "Bravo Bob\u{202F}!")
        #expect(result.lines.first?.name == "Bob")
        #expect(result.lines.filter(\.isWinner).count == 1)
        #expect(result.spokenSummary.hasPrefix("Partie terminée. Vainqueur\u{00A0}: Bob, "))
        #expect(result.rulesReminder.contains("100"))
    }

    @Test("Partie en cours : pas de résumé")
    func inProgress() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.nearEnd.apply(to: repository)
        let game = try repository.game(id: UITestSeed.nearEnd.activeGameID)
        #expect(GameOverSummary(game: game) == nil)
    }

    @Test("Incohérence : les scores de fin sont totalsAtEnd, cohérents avec les vainqueurs")
    func inconsistencyUsesTotalsAtEnd() throws {
        let alice = Participant(displayName: "Alice", displayOrder: 0)
        let bob = Participant(displayName: "Bob", displayOrder: 1)
        let rounds = [
            RoundInput(
                index: 1,
                closingParticipantID: bob.id,
                entries: [.points(alice.id, rawScore: 100), .points(bob.id, rawScore: 5)]
            ),
            RoundInput(
                index: 2,
                closingParticipantID: alice.id,
                entries: [.points(alice.id, rawScore: 3), .points(bob.id, rawScore: 50)]
            ),
        ]
        let now = Date(timeIntervalSince1970: 0)
        let game = try SavedGame(
            id: UUID(),
            title: nil,
            lifecycle: .active,
            rules: .classic,
            participants: [alice, bob],
            rounds: rounds,
            roundInfo: [:],
            createdAt: now,
            updatedAt: now,
            finishedAt: nil,
            archivedAt: nil
        )
        #expect(game.computation.inconsistency != nil)
        let result = try #require(GameOverSummary(game: game))
        #expect(result.roundCount == 1)
        #expect(result.winnerNames == ["Bob"])
        #expect(result.lines.map(\.total) == [5, 100])
        // Les cumuls courants (après la manche 2) diffèrent : ils ne sont pas utilisés.
        #expect(game.computation.totals[alice.id] == 103)
    }

    @Test("Jointure des prénoms")
    func joinNames() {
        #expect(GameOverSummary.join(["Bob"]) == "Bob")
        #expect(GameOverSummary.join(["Bob", "Chloé"]) == "Bob et Chloé")
        #expect(GameOverSummary.join(["Alice", "Bob", "Chloé"]) == "Alice, Bob et Chloé")
    }
}
#endif
