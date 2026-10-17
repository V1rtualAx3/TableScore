import Foundation
import Testing
import TableScoreKit
@testable import TableScore

/// Dépôt dont toute lecture échoue (affichage d'erreur de l'accueil).
@MainActor
private final class UnreadableRepository: GameRepository {
    let error: GameRepositoryError

    init(error: GameRepositoryError) {
        self.error = error
    }

    func activeGame() throws(GameRepositoryError) -> SavedGame? { throw error }
    func game(id: UUID) throws(GameRepositoryError) -> SavedGame { throw error }
    func closedGames() throws(GameRepositoryError) -> [GameListing] { throw error }
    func createGame(
        id: UUID, participants: [Participant], rules: GameRules, title: String?
    ) throws(GameRepositoryError) -> SavedGame { throw error }
    func appendRound(_ round: RoundInput, toGame gameID: UUID) throws(GameRepositoryError) -> AppendRoundOutcome {
        throw error
    }
    func replaceRound(
        _ round: RoundInput, inGame gameID: UUID, resolution: EarlyEndResolution
    ) throws(GameRepositoryError) -> RoundReplacementOutcome { throw error }
    func deleteLastRound(ofGame gameID: UUID) throws(GameRepositoryError) -> RoundDeletion { throw error }
    func finishGame(id: UUID) throws(GameRepositoryError) -> SavedGame { throw error }
    func reopenGame(id: UUID) throws(GameRepositoryError) -> SavedGame { throw error }
    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame { throw error }
    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool { throw error }
}

@Suite("Accueil : état et textes")
@MainActor
struct HomeModelTests {
    private func players(_ count: Int) -> [Participant] {
        (0..<count).map { Participant(id: UUID(), displayName: "Joueur \($0 + 1)", displayOrder: $0) }
    }

    @Test("Aucune partie : état vide, pas de confirmation")
    func noGame() {
        let model = HomeModel(repository: InMemoryGameRepository())
        #expect(model.state == .loading)
        model.load()
        #expect(model.state == .empty)
        #expect(model.activeGame == nil)
        #expect(!model.needsReplacementConfirmation)
    }

    @Test("Partie active sans manche : résumé et confirmation requise")
    func activeGameWithoutRound() throws {
        let repository = InMemoryGameRepository()
        let created = try repository.createGame(id: UUID(), participants: players(4), rules: .classic)
        let model = HomeModel(repository: repository)
        model.load()

        let summary = try #require(model.activeGame)
        #expect(summary.id == created.id)
        #expect(summary.playerCount == 4)
        #expect(summary.roundsPlayed == 0)
        #expect(!summary.isOver)
        #expect(model.needsReplacementConfirmation)
    }

    #if DEBUG
    @Test("Partie active avec manches : nombre de manches du dépôt")
    func activeGameWithRounds() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.nearEnd.apply(to: repository)
        let model = HomeModel(repository: repository)
        model.load()

        let summary = try #require(model.activeGame)
        #expect(summary.id == UITestSeed.nearEnd.activeGameID)
        #expect(summary.playerCount == 3)
        #expect(summary.roundsPlayed == 3)
        #expect(!summary.isOver)
        #expect(model.needsReplacementConfirmation)
    }

    @Test("Partie terminée selon le moteur : reprise proposée, aucune confirmation de remplacement")
    func gameOverByEngine() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.tieEnd.apply(to: repository)
        let model = HomeModel(repository: repository)
        model.load()

        let summary = try #require(model.activeGame)
        #expect(summary.isOver)
        #expect(!model.needsReplacementConfirmation)
    }

    @Test("Les parties rangées ne comptent pas comme partie en cours")
    func closedGamesAreNotActive() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.withHistory.apply(to: repository)
        let archived = try repository.archiveGame(id: UITestSeed.withHistory.activeGameID)
        let model = HomeModel(repository: repository)
        model.load()
        #expect(archived.lifecycle == .archived)
        #expect(model.state == .empty)
    }
    #endif

    @Test("Rechargement après écriture : l'état suit le dépôt")
    func reloadFollowsRepository() throws {
        let repository = InMemoryGameRepository()
        let model = HomeModel(repository: repository)
        model.load()
        #expect(model.state == .empty)

        let game = try repository.createGame(id: UUID(), participants: players(2), rules: .classic)
        model.load()
        #expect(model.activeGame?.id == game.id)

        _ = try repository.archiveGame(id: game.id)
        model.load()
        #expect(model.state == .empty)
    }

    @Test("Erreur de lecture : message utilisateur générique, jamais d'état vide trompeur")
    func readFailure() {
        let diagnostic = "/private/var/secret.store"
        let repository = UnreadableRepository(error: .storageFailure(.read, message: diagnostic))
        let model = HomeModel(repository: repository)
        model.load()

        guard case .failed(let message) = model.state else {
            Issue.record("Une erreur de lecture doit produire l'état d'échec.")
            return
        }
        #expect(message == GameRepositoryError.storageFailure(.read, message: diagnostic).userFacingMessage)
        #expect(!message.contains(diagnostic))
        #expect(model.activeGame == nil)
        #expect(!model.needsReplacementConfirmation)
    }

    @Test("Textes : joueurs et manches, singulier et pluriel")
    func summaryText() {
        #expect(HomeModel.summaryText(playerCount: 4, roundsPlayed: 3) == "4 joueurs · 3 manches jouées")
        #expect(HomeModel.summaryText(playerCount: 2, roundsPlayed: 1) == "2 joueurs · 1 manche jouée")
        #expect(HomeModel.summaryText(playerCount: 2, roundsPlayed: 0) == "2 joueurs · aucune manche jouée")
        #expect(HomeModel.summaryText(playerCount: 1, roundsPlayed: 2) == "1 joueur · 2 manches jouées")
    }

    @Test("Dernier enregistrement : « à l'instant » sous la minute, relatif au-delà")
    func lastSavedText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HomeModel.lastSavedText(updatedAt: now.addingTimeInterval(-20), now: now) == "modifiée à l'instant")
        let older = HomeModel.lastSavedText(updatedAt: now.addingTimeInterval(-300), now: now)
        #expect(older.hasPrefix("modifiée "))
        #expect(older != "modifiée à l'instant")
    }
}
