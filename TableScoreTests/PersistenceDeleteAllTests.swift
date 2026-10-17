import Foundation
import SwiftData
import Testing
import TableScoreKit
@testable import TableScore

/// Suppression globale (« Supprimer toutes les données ») : une seule transaction, tout ou rien.
@Suite("Persistance : suppression de toutes les parties")
@MainActor
struct PersistenceDeleteAllTests {
    private typealias Fx = PersistenceFixtures

    /// Une partie terminée (Bob dépasse le seuil), puis une partie active avec une manche.
    private func populate(_ repo: any GameRepository) throws {
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: GameRules(targetScore: 10))
        _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 2, Fx.bob: 12]), toGame: Fx.gameA)
        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(3), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 5, Fx.bob: 3, Fx.chloe: 9]), toGame: Fx.gameB)
    }

    @Test("Tout est supprimé : active, terminées, et l'opération est idempotente", arguments: RepositoryKind.allCases)
    func deletesEverything(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        try populate(repo)
        #expect(try repo.activeGame() != nil)
        #expect(try repo.closedGames().count == 1)

        try repo.deleteAllGames()

        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames().isEmpty)
        let error = repositoryError { _ = try repo.game(id: Fx.gameA) }
        #expect(error == GameRepositoryError.gameNotFound(Fx.gameA))

        // Rien à supprimer : aucune erreur.
        try repo.deleteAllGames()
        // Le dépôt reste utilisable.
        _ = try repo.createGame(id: Fx.gameC, participants: Fx.players(2), rules: .classic)
        #expect(try repo.activeGame()?.id == Fx.gameC)
    }

    @Test("SwiftData : aucun enregistrement résiduel (parties, joueurs, manches)")
    func swiftDataLeavesNoRecord() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let clock = TestClock()
        let repo = SwiftDataGameRepository(container: container, now: { clock.next() })
        try populate(repo)

        try repo.deleteAllGames()

        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<GameRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ParticipantRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RoundRecord>()) == 0)
    }

    @Test("SwiftData : une partie illisible est aussi supprimée")
    func swiftDataDeletesCorruptedGame() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let context = ModelContext(container)
        let raw = GameRecord(
            gameID: Fx.gameC,
            title: nil,
            lifecycleRaw: "zombie",
            rulesPayload: Data("{}".utf8),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            finishedAt: nil,
            archivedAt: nil
        )
        context.insert(raw)
        try context.save()

        let repo = SwiftDataGameRepository(container: container)
        #expect(try repo.closedGames().count == 1)
        try repo.deleteAllGames()
        #expect(try repo.closedGames().isEmpty)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<GameRecord>()) == 0)
    }

    @Test("SwiftData : échec de sauvegarde ⇒ aucune suppression partielle, erreur d'écriture, nouvel essai possible")
    func swiftDataFailedDeleteAllIsAtomic() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let clock = TestClock()
        let failures = SaveFailureSwitch()
        let repo = SwiftDataGameRepository(
            container: container,
            now: { clock.next() },
            saveHandler: { try failures.save($0) }
        )
        try populate(repo)
        let active = try repo.game(id: Fx.gameB)
        let closed = try repo.closedGames()

        failures.failNextSave = true
        let error = repositoryError { try repo.deleteAllGames() }
        #expect(error?.isWriteFailure == true)

        #expect(try repo.game(id: Fx.gameB) == active)
        #expect(try repo.closedGames() == closed)
        let fresh = SwiftDataGameRepository(container: container)
        #expect(try fresh.game(id: Fx.gameB) == active)
        #expect(try fresh.closedGames() == closed)

        try repo.deleteAllGames()
        #expect(try fresh.activeGame() == nil)
        #expect(try fresh.closedGames().isEmpty)
    }

    #if DEBUG
    @Test("Dépôt en mémoire : échec simulé ⇒ rien n'est supprimé")
    func inMemoryFailedDeleteAllChangesNothing() throws {
        let clock = TestClock()
        let repo = InMemoryGameRepository(now: { clock.next() })
        try populate(repo)
        let active = try repo.game(id: Fx.gameB)
        let closed = try repo.closedGames()

        repo.simulatesWriteFailure = true
        let error = repositoryError { try repo.deleteAllGames() }
        #expect(error?.isWriteFailure == true)
        repo.simulatesWriteFailure = false

        #expect(try repo.activeGame() == active)
        #expect(try repo.closedGames() == closed)
    }
    #endif
}
