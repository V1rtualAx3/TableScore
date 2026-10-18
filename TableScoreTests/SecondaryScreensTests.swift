// Suites fondées sur `InMemoryGameRepository` (Debug uniquement ; sentinelle dans TableScoreTests.swift).
#if DEBUG
import Foundation
import SwiftData
import Testing
import TableScoreKit
@testable import TableScore

/// Écrans secondaires (Lot 2, T7) : parties terminées, paramètres. Aucune règle de score testée
/// ici : seulement l'affichage des résultats du moteur et la suppression confirmée.
@Suite("Écrans secondaires : parties terminées et paramètres")
@MainActor
struct SecondaryScreensTests {
    private typealias Fx = PersistenceFixtures

    /// A : terminée avec co-vainqueurs Alice et Bob (seuil 10, 3 joueurs, 1 manche).
    /// B : interrompue (archivée avant la fin). C : partie active (non listée).
    private func populate(_ repo: any GameRepository) throws {
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(3), rules: GameRules(targetScore: 10))
        _ = try repo.appendRound(
            Fx.round(1, closer: Fx.chloe, [Fx.alice: 10, Fx.bob: 10, Fx.chloe: 15]),
            toGame: Fx.gameA
        )
        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 4, Fx.bob: 9]), toGame: Fx.gameB)
        _ = try repo.createGame(id: Fx.gameC, participants: Fx.players(2), rules: .classic)
    }

    private func makeRepository() -> InMemoryGameRepository {
        let clock = TestClock()
        return InMemoryGameRepository(now: { clock.next() })
    }

    // MARK: Liste

    @Test("Liste : terminée, interrompue, co-vainqueurs, manches ; la partie active est exclue")
    func listsClosedGames() throws {
        let repo = makeRepository()
        try populate(repo)
        let model = FinishedGamesModel(repository: repo)
        #expect(model.isLoaded == false)

        model.load()

        #expect(model.isLoaded)
        #expect(model.loadErrorMessage == nil)
        #expect(model.rows.map(\.id) == [Fx.gameB, Fx.gameA])

        let interrupted = model.rows[0]
        #expect(interrupted.kind == .interrupted)
        #expect(interrupted.winnerNames.isEmpty)
        #expect(interrupted.roundCount == 1)
        #expect(interrupted.playerNames == ["Alice", "Bob"])

        let finished = model.rows[1]
        #expect(finished.kind == .finished)
        #expect(finished.winnerNames == ["Alice", "Bob"])
        #expect(finished.hasCoWinners)
        #expect(finished.roundCount == 1)
        #expect(finished.playerNames == ["Alice", "Bob", "Chloé"])
    }

    @Test("Liste vide : aucun élément, chargement terminé")
    func emptyList() {
        let model = FinishedGamesModel(repository: makeRepository())
        model.load()
        #expect(model.isLoaded)
        #expect(model.rows.isEmpty)
    }

    @Test("Partie illisible : listée « illisible » puis supprimable")
    func unreadableGameIsListedAndDeletable() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let context = ModelContext(container)
        let date = Date(timeIntervalSinceReferenceDate: 700_000_000)
        context.insert(GameRecord(
            gameID: Fx.gameC,
            title: nil,
            lifecycleRaw: "zombie",
            rulesPayload: Data("{}".utf8),
            createdAt: date,
            updatedAt: date,
            finishedAt: nil,
            archivedAt: nil
        ))
        try context.save()

        let model = FinishedGamesModel(repository: SwiftDataGameRepository(container: container))
        model.load()
        #expect(model.rows.map(\.kind) == [.unreadable])
        #expect(model.rows.first?.isReadable == false)

        model.requestDeletion(of: Fx.gameC)
        #expect(model.confirmDeletion())
        #expect(model.rows.isEmpty)
    }

    // MARK: Suppression

    @Test("Suppression : rien n'est effacé avant confirmation, annuler conserve")
    func deletionRequiresConfirmation() throws {
        let repo = makeRepository()
        try populate(repo)
        let model = FinishedGamesModel(repository: repo)
        model.load()

        #expect(model.confirmDeletion() == false)
        #expect(model.rows.count == 2)

        model.requestDeletion(of: Fx.gameB)
        #expect(model.pendingDeletionID == Fx.gameB)
        #expect(model.rows.count == 2)
        model.cancelDeletion()
        #expect(model.pendingDeletionID == nil)
        #expect(model.confirmDeletion() == false)
        #expect(try repo.closedGames().count == 2)
    }

    @Test("Suppression confirmée : seule la partie choisie disparaît, la partie active est intacte")
    func confirmedDeletionRemovesOnlyThatGame() throws {
        let repo = makeRepository()
        try populate(repo)
        let model = FinishedGamesModel(repository: repo)
        model.load()

        model.requestDeletion(of: Fx.gameB)
        #expect(model.confirmDeletion())

        #expect(model.rows.map(\.id) == [Fx.gameA])
        #expect(model.pendingDeletionID == nil)
        #expect(try repo.closedGames().map(\.id) == [Fx.gameA])
        #expect(try repo.activeGame()?.id == Fx.gameC)
    }

    #if DEBUG
    @Test("Échec d'écriture : message générique, liste inchangée, pas de faux succès")
    func failedDeletionKeepsGame() throws {
        let repo = makeRepository()
        try populate(repo)
        let model = FinishedGamesModel(repository: repo)
        model.load()

        repo.simulatesWriteFailure = true
        model.requestDeletion(of: Fx.gameB)
        #expect(model.confirmDeletion() == false)

        #expect(model.hasDeletionError)
        #expect(model.deletionErrorMessage?.isEmpty == false)
        #expect(model.rows.count == 2)
        model.hasDeletionError = false
        #expect(model.deletionErrorMessage == nil)
    }
    #endif

    // MARK: Paramètres

    @Test("Suppression globale : double confirmation obligatoire")
    func deleteAllNeedsTwoConfirmations() throws {
        let repo = makeRepository()
        try populate(repo)
        let model = SettingsModel(repository: repo)

        // Sans demande, ou après la première étape seulement : aucun effet.
        #expect(model.confirmDeleteAll() == false)
        model.beginDeletion()
        #expect(model.deletionStep == .first)
        #expect(model.confirmDeleteAll() == false)
        #expect(try repo.activeGame() != nil)

        model.cancelDeletion()
        #expect(model.deletionStep == .idle)
        model.continueDeletion()
        #expect(model.deletionStep == .idle)

        model.beginDeletion()
        model.continueDeletion()
        #expect(model.deletionStep == .lastConfirmation)
        #expect(model.confirmDeleteAll())
        #expect(model.deletionStep == .idle)
        #expect(model.didDeleteAll)
        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames().isEmpty)

        // Une nouvelle demande réinitialise le message de succès.
        model.beginDeletion()
        #expect(model.didDeleteAll == false)
    }

    #if DEBUG
    @Test("Suppression globale en échec : erreur affichable, aucune donnée perdue")
    func deleteAllFailureKeepsData() throws {
        let repo = makeRepository()
        try populate(repo)
        let model = SettingsModel(repository: repo)

        repo.simulatesWriteFailure = true
        model.beginDeletion()
        model.continueDeletion()
        #expect(model.confirmDeleteAll() == false)

        #expect(model.hasError)
        #expect(model.didDeleteAll == false)
        repo.simulatesWriteFailure = false
        #expect(try repo.activeGame()?.id == Fx.gameC)
        #expect(try repo.closedGames().count == 2)
    }
    #endif

    @Test("Version : numéro court, build distinct, repli")
    func versionText() {
        #expect(SettingsModel.versionText(shortVersion: "1.2", build: "7") == "1.2 (7)")
        #expect(SettingsModel.versionText(shortVersion: "1.2", build: "1.2") == "1.2")
        #expect(SettingsModel.versionText(shortVersion: "1.2", build: nil) == "1.2")
        #expect(SettingsModel.versionText(shortVersion: nil, build: "7") == "Inconnue")
        #expect(SettingsModel.versionText(shortVersion: "  ", build: "7") == "Inconnue")
    }
}
#endif
