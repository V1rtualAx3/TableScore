#if DEBUG
import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Modèle du tableau des scores : données d'affichage issues du moteur, bannière, rejouer, abandon.
@Suite("Tableau des scores (GameModel)")
@MainActor
struct GameModelTests {
    private func makeModel(_ seed: UITestSeed) throws -> (GameModel, InMemoryGameRepository) {
        let repository = InMemoryGameRepository()
        try seed.apply(to: repository)
        let model = GameModel(gameID: seed.activeGameID, repository: repository)
        model.load()
        return (model, repository)
    }

    @Test("Huit joueurs : ordre stable, co-leaders à moins 7, négatifs conservés")
    func eightPlayersCoLeaders() throws {
        let (model, _) = try makeModel(.eightPlayers)
        let rows = model.rows
        #expect(rows.map(\.name) == ["Alice", "Bastien", "Chloé", "Dimitri", "Élodie", "Farid", "Gaëlle", "Marie-Charlotte"])
        #expect(rows.map(\.position) == Array(0..<8))
        #expect(rows.map(\.total) == [15, 16, -7, 55, -7, 17, 9, 71])
        #expect(rows.filter(\.isLeader).map(\.name) == ["Chloé", "Élodie"])
        #expect(rows.filter(\.isLeader).allSatisfy { $0.rank == 1 && $0.gapToLeader == nil })
        #expect(rows[0].rank == 4)
        #expect(rows[0].gapToLeader == 22)
        #expect(model.rankedRows.map(\.total) == [-7, -7, 9, 15, 16, 17, 55, 71])
        #expect(model.headerTitle == "Manche 3")
        #expect(model.playerCount == 8)
        #expect(model.canAddRound)
        #expect(!model.hasInconsistency)
        #expect(model.banner == nil)
    }

    @Test("Proche de la fin : partie en cours, CTA disponible")
    func nearEnd() throws {
        let (model, _) = try makeModel(.nearEnd)
        #expect(model.rows.map(\.total) == [88, 60, 23])
        #expect(model.rows.filter(\.isLeader).map(\.name) == ["Chloé"])
        #expect(!model.isOver)
        #expect(model.canAddRound)
        #expect(model.canAbandon)
    }

    @Test("Égalité de fin : partie terminée, co-vainqueurs, pas de nouvelle manche")
    func tieEnd() throws {
        let (model, _) = try makeModel(.tieEnd)
        #expect(model.isOver)
        #expect(!model.canAddRound)
        #expect(!model.canAbandon)
        #expect(model.headerTitle == "Partie terminée")
        #expect(model.rows.map(\.total) == [105, 26, 26])
        #expect(model.rows.filter(\.isLeader).map(\.name) == ["Bob", "Chloé"])
        guard case .finished(_, let winnerIDs)? = model.game?.computation.status else {
            Issue.record("La partie devrait être terminée.")
            return
        }
        #expect(winnerIDs.count == 2)
    }

    @Test("Partie introuvable : état d'échec sans crash")
    func gameNotFound() {
        let model = GameModel(gameID: UUID(), repository: InMemoryGameRepository())
        model.load()
        guard case .failed(let message) = model.loadState else {
            Issue.record("Un échec était attendu.")
            return
        }
        #expect(!message.isEmpty)
        #expect(model.rows.isEmpty)
        #expect(!model.canAddRound)
    }

    @Test("Bannière : aucune au premier chargement, « Manche 4 enregistrée » après ajout, doublement signalé")
    func bannerAfterAppend() throws {
        let (model, repository) = try makeModel(.nearEnd)
        #expect(model.banner == nil)
        let key = UITestSeed.GameKey.nearEnd
        let ids = (0..<3).map { key.participantID(position: $0) }
        // Chloé clôt avec 10 alors qu'Alice (5) et Bob (8) ont fait moins : score doublé (10 → 20).
        let round = RoundInput(
            id: UUID(),
            index: 4,
            closingParticipantID: ids[2],
            entries: [
                .points(ids[0], rawScore: 5),
                .points(ids[1], rawScore: 8),
                .points(ids[2], rawScore: 10),
            ]
        )
        _ = try repository.appendRound(round, toGame: key.id)
        model.load()

        #expect(model.banner?.message == "Manche 4 enregistrée")
        #expect(model.banner?.detail?.contains("Chloé") == true)
        #expect(model.banner?.detail?.contains("10 → 20") == true)
        #expect(model.savedRoundCount == 1)
        #expect(model.rows.map(\.total) == [93, 68, 43])
        #expect(model.headerTitle == "Manche 5")

        model.dismissBanner()
        #expect(model.banner == nil)
        model.load()
        #expect(model.banner == nil, "Un rechargement sans nouvelle manche ne recrée pas la bannière.")
    }

    @Test("Rejouer : mêmes prénoms, même ordre, mêmes règles, nouveaux identifiants, idempotent")
    func replay() throws {
        let (model, repository) = try makeModel(.tieEnd)
        let original = try #require(model.game)
        let newID = try #require(model.replay())
        #expect(newID != original.id)
        #expect(model.replay() == newID)

        let created = try repository.game(id: newID)
        #expect(created.participants.map(\.displayName) == original.participants.map(\.displayName))
        #expect(created.participants.map(\.displayOrder) == original.participants.map(\.displayOrder))
        #expect(Set(created.participants.map(\.id)).isDisjoint(with: original.participants.map(\.id)))
        #expect(created.rules == original.rules)
        #expect(created.rounds.isEmpty)
        #expect(created.lifecycle == .active)
    }

    @Test("Abandonner archive la partie sans la supprimer")
    func abandon() throws {
        let (model, repository) = try makeModel(.nearEnd)
        #expect(model.abandon())
        let game = try repository.game(id: UITestSeed.nearEnd.activeGameID)
        #expect(game.lifecycle == .archived)
        #expect(game.rounds.count == 3)
    }
}
#endif
