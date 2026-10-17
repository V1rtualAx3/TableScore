import Foundation
import SwiftData
import Testing
import TableScoreKit
@testable import TableScore

// MARK: - Utilitaires partagés des tests de persistance

/// Identifiants et données déterministes.
enum PersistenceFixtures {
    static func uuid(_ n: UInt8) -> UUID {
        UUID(uuid: (0x7A, 0x5C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, n))
    }

    static let alice = uuid(1)
    static let bob = uuid(2)
    static let chloe = uuid(3)
    static let gameA = uuid(0xA1)
    static let gameB = uuid(0xB2)
    static let gameC = uuid(0xC3)

    /// `count` joueurs : Alice = uuid(1), Bob = uuid(2), Chloé = uuid(3)…
    static func players(_ count: Int) -> [Participant] {
        let names = ["Alice", "Bob", "Chloé", "David", "Emma", "Farid", "Gaëlle", "Hugo", "Inès"]
        return (0..<count).map { offset in
            Participant(
                id: uuid(UInt8(offset + 1)),
                displayName: offset < names.count ? names[offset] : "Joueur \(offset + 1)",
                displayOrder: offset
            )
        }
    }

    /// Manche saisie en points, entrées dans l'ordre fourni.
    static func round(_ index: Int, closer: UUID, _ scores: KeyValuePairs<UUID, Int>, id: UUID = UUID()) -> RoundInput {
        RoundInput(
            id: id,
            index: index,
            closingParticipantID: closer,
            entries: scores.map { RoundEntry.points($0.key, rawScore: $0.value) }
        )
    }

    /// Colonne 7/7/7 (retirée automatiquement), 1/2/3, colonne marquée retirée, 12/−2/0 ⇒ 16.
    static func cardGrid() throws -> CardGrid {
        try CardGrid(columns: [
            CardColumn(top: 7, middle: 7, bottom: 7),
            CardColumn(top: 1, middle: 2, bottom: 3),
            CardColumn(top: nil, middle: nil, bottom: nil, isMarkedRemoved: true),
            CardColumn(top: 12, middle: -2, bottom: 0),
        ])
    }
}

/// Horloge déterministe : chaque lecture avance d'une minute.
@MainActor
final class TestClock {
    private(set) var current = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func next() -> Date {
        current = current.addingTimeInterval(60)
        return current
    }
}

/// Les deux implémentations doivent respecter exactement le même contrat.
enum RepositoryKind: String, CaseIterable, Sendable, CustomStringConvertible {
    case swiftData
    case inMemory

    var description: String { rawValue }

    @MainActor
    func make(clock: TestClock) throws -> any GameRepository {
        switch self {
        case .swiftData:
            let container = try PersistenceController.makeContainer(storage: .inMemory)
            return SwiftDataGameRepository(container: container, now: { clock.next() })
        case .inMemory:
            return InMemoryGameRepository(now: { clock.next() })
        }
    }
}

/// Exécute `body` et renvoie l'erreur du dépôt attendue (enregistre un échec sinon).
@MainActor
func repositoryError(_ body: () throws -> Void) -> GameRepositoryError? {
    do {
        try body()
    } catch let error as GameRepositoryError {
        return error
    } catch {
        Issue.record("Erreur inattendue : \(error)")
        return nil
    }
    Issue.record("Une erreur du dépôt était attendue.")
    return nil
}

extension GameRepositoryError {
    /// Cause élémentaire d'un refus du moteur (sans l'enveloppe `.invalidRound`).
    var validationReason: ValidationError? {
        if case .validation(let error) = self { return error.underlyingReason }
        return nil
    }

    var isWriteFailure: Bool {
        if case .storageFailure(.write, _) = self { return true }
        return false
    }
}

// MARK: - Contrat commun (SwiftData en mémoire + dépôt en mémoire)

@Suite("Persistance : contrat du dépôt de parties")
@MainActor
struct PersistenceContractTests {
    private typealias Fx = PersistenceFixtures

    @Test("Création : partie active normalisée, relue à l'identique", arguments: RepositoryKind.allCases)
    func createAndLoad(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        #expect(try repo.activeGame() == nil)

        var players = Fx.players(3)
        players[0].displayName = "  Alice  "
        let game = try repo.createGame(
            id: Fx.gameA,
            participants: Array(players.reversed()),
            rules: .classic,
            title: "  Soirée  "
        )

        #expect(game.title == "Soirée")
        #expect(game.participants.map(\.displayName) == ["Alice", "Bob", "Chloé"])
        #expect(game.lifecycle == .active)
        #expect(game.rounds.isEmpty)
        #expect(game.computation.status == .inProgress)
        #expect(try repo.activeGame() == game)
        #expect(try repo.game(id: Fx.gameA) == game)
        #expect(try repo.closedGames().isEmpty)
    }

    @Test("Création : 1 et 9 joueurs refusés par le moteur, rien n'est écrit", arguments: RepositoryKind.allCases)
    func createRejectsInvalidPlayerCount(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())

        let tooFew = repositoryError { _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(1), rules: .classic) }
        #expect(tooFew?.validationReason == .participantCountOutOfRange(count: 1))
        let tooMany = repositoryError { _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(9), rules: .classic) }
        #expect(tooMany?.validationReason == .participantCountOutOfRange(count: 9))

        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames().isEmpty)
        #expect(try repo.createGame(id: Fx.gameA, participants: Fx.players(8), rules: .classic).participants.count == 8)
    }

    @Test("Création idempotente par identifiant ; contenu différent ⇒ conflit", arguments: RepositoryKind.allCases)
    func createIsIdempotent(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        let first = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let second = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)

        #expect(second == first)
        #expect(try repo.activeGame() == first)
        #expect(try repo.closedGames().isEmpty)

        let conflict = repositoryError { _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(3), rules: .classic) }
        #expect(conflict == GameRepositoryError.identifierConflict(Fx.gameA))
        #expect(try repo.activeGame() == first)
    }

    @Test("Une seule partie active : l'ancienne est interrompue ou terminée", arguments: RepositoryKind.allCases)
    func singleActiveGame(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 10, Fx.bob: 3]), toGame: Fx.gameA)

        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)
        #expect(try repo.activeGame()?.id == Fx.gameB)
        let interrupted = try repo.game(id: Fx.gameA)
        #expect(interrupted.lifecycle == .archived)
        #expect(interrupted.isInterrupted)
        #expect(interrupted.archivedAt != nil)
        #expect(interrupted.rounds.count == 1)

        // B atteint 100 : elle reste active (correction possible) jusqu'à la décision suivante.
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 100, Fx.bob: 0]), toGame: Fx.gameB)
        #expect(try repo.game(id: Fx.gameB).isOver)
        #expect(try repo.game(id: Fx.gameB).lifecycle == .active)

        _ = try repo.createGame(id: Fx.gameC, participants: Fx.players(2), rules: .classic)
        let finished = try repo.game(id: Fx.gameB)
        #expect(finished.lifecycle == .finished)
        #expect(!finished.isInterrupted)
        #expect(finished.finishedAt != nil)
        #expect(try repo.activeGame()?.id == Fx.gameC)
        #expect(try repo.closedGames().map(\.id) == [Fx.gameB, Fx.gameA])
    }

    @Test("Ajout idempotent : double soumission sans doublon, conflit si contenu différent", arguments: RepositoryKind.allCases)
    func appendIsIdempotent(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 10, Fx.bob: 24])

        guard case .inserted(let saved) = try repo.appendRound(round, toGame: Fx.gameA) else {
            Issue.record("La première soumission doit être enregistrée.")
            return
        }
        #expect(try repo.appendRound(round, toGame: Fx.gameA) == .alreadySaved(saved))

        // Même contenu, entrées dans un autre ordre : toujours la même manche.
        let reordered = RoundInput(
            id: round.id,
            index: 1,
            closingParticipantID: Fx.alice,
            entries: Array(round.entries.reversed())
        )
        #expect(try repo.appendRound(reordered, toGame: Fx.gameA) == .alreadySaved(saved))

        let altered = Fx.round(1, closer: Fx.alice, [Fx.alice: 11, Fx.bob: 24], id: round.id)
        let conflict = repositoryError { _ = try repo.appendRound(altered, toGame: Fx.gameA) }
        #expect(conflict == GameRepositoryError.identifierConflict(round.id))
        #expect(try repo.game(id: Fx.gameA) == saved)
        #expect(saved.rounds.count == 1)
    }

    @Test("Ajout validé par le moteur : manche incomplète, indice faux ou partie inconnue refusés", arguments: RepositoryKind.allCases)
    func appendValidatesWithEngine(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)

        let incomplete = RoundInput(
            id: UUID(),
            index: 1,
            closingParticipantID: Fx.alice,
            entries: [.points(Fx.alice, rawScore: 3)]
        )
        let missing = repositoryError { _ = try repo.appendRound(incomplete, toGame: Fx.gameA) }
        #expect(missing?.validationReason == .missingEntry(participantID: Fx.bob))

        let wrongIndex = repositoryError {
            _ = try repo.appendRound(Fx.round(2, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]), toGame: Fx.gameA)
        }
        #expect(wrongIndex?.validationReason == .roundIndexMismatch(expected: 1, found: 2))

        let unknownGame = UUID()
        let notFound = repositoryError {
            _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]), toGame: unknownGame)
        }
        #expect(notFound == GameRepositoryError.gameNotFound(unknownGame))
        #expect(try repo.game(id: Fx.gameA).rounds.isEmpty)
    }

    @Test("Ajout refusé après la manche qui termine la partie", arguments: RepositoryKind.allCases)
    func appendRefusedAfterGameEnd(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 100, Fx.bob: 0]), toGame: Fx.gameA)

        let error = repositoryError {
            _ = try repo.appendRound(Fx.round(2, closer: Fx.bob, [Fx.alice: 1, Fx.bob: 0]), toGame: Fx.gameA)
        }
        #expect(error?.validationReason == .gameAlreadyFinished(atRoundIndex: 1))
        #expect(try repo.game(id: Fx.gameA).rounds.count == 1)
    }

    @Test("Saisie « cartes » : grille conservée et score brut cohérent", arguments: RepositoryKind.allCases)
    func cardEntryIsStored(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let grid = try Fx.cardGrid()
        let cardEntry = try RoundEntry.cards(Fx.alice, grid: grid)
        #expect(cardEntry.rawScore == 16)
        let round = RoundInput(
            id: UUID(),
            index: 1,
            closingParticipantID: Fx.bob,
            entries: [cardEntry, .points(Fx.bob, rawScore: 20)]
        )

        let game = try repo.appendRound(round, toGame: Fx.gameA).game
        #expect(game.rounds[0].entry(for: Fx.alice)?.cardGrid == grid)
        #expect(game.rounds[0].entry(for: Fx.alice)?.inputMethod == .cards)
        #expect(game.computation.totals == [Fx.alice: 16, Fx.bob: 40])
        #expect(try repo.game(id: Fx.gameA) == game)
    }

    @Test("Correction d'une ancienne manche : recalcul de toutes les suivantes", arguments: RepositoryKind.allCases)
    func correctionRecomputesFollowingRounds(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        let players = Fx.players(3)
        _ = try repo.createGame(id: Fx.gameA, participants: players, rules: .classic)
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 10, Fx.bob: 24, Fx.chloe: 10])
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: 5, Fx.bob: 3, Fx.chloe: 8])
        let r3 = Fx.round(3, closer: Fx.chloe, [Fx.alice: 2, Fx.bob: 4, Fx.chloe: 6])
        for round in [r1, r2, r3] {
            _ = try repo.appendRound(round, toGame: Fx.gameA)
        }
        let before = try repo.game(id: Fx.gameA)
        #expect(before.computation.totals == [Fx.alice: 27, Fx.bob: 31, Fx.chloe: 30])

        // Chloé avait 11 : Alice n'est plus à égalité, sa pénalité disparaît.
        let corrected = Fx.round(1, closer: Fx.alice, [Fx.alice: 10, Fx.bob: 24, Fx.chloe: 11], id: r1.id)
        guard case .saved(let updated, let removed) = try repo.replaceRound(corrected, inGame: Fx.gameA) else {
            Issue.record("La correction doit être enregistrée.")
            return
        }
        let expected = try ScoreEngine.computeGame(participants: players, rounds: [corrected, r2, r3], rules: .classic)
        #expect(removed.isEmpty)
        #expect(updated.computation.rounds[0].scoring.closingEffectiveScore == 10)
        #expect(updated.computation.totals == [Fx.alice: 17, Fx.bob: 31, Fx.chloe: 31])
        #expect(updated.computation == expected)
        #expect(updated.rounds.map(\.id) == [r1.id, r2.id, r3.id])
        #expect(try repo.game(id: Fx.gameA) == updated)

        // Correction identique : aucune écriture (date inchangée), résultat distinct.
        #expect(try repo.replaceRound(corrected, inGame: Fx.gameA) == .unchanged(updated))
    }

    @Test("Correction : manche inconnue ou indice modifié refusés", arguments: RepositoryKind.allCases)
    func correctionRejectsUnknownRoundOrIndexChange(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        let before = try repo.appendRound(r1, toGame: Fx.gameA).game

        let unknown = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        let unknownError = repositoryError { _ = try repo.replaceRound(unknown, inGame: Fx.gameA) }
        #expect(unknownError?.validationReason == .unknownRound(unknown.id))

        let moved = Fx.round(2, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2], id: r1.id)
        let movedError = repositoryError { _ = try repo.replaceRound(moved, inGame: Fx.gameA) }
        #expect(movedError?.validationReason == .roundIndexMismatch(expected: 1, found: 2))
        #expect(try repo.game(id: Fx.gameA) == before)
    }

    @Test("§4.6 : correction révélant une fin anticipée ⇒ rien n'est écrit sans décision", arguments: RepositoryKind.allCases)
    func earlyEndRequiresExplicitDecision(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let r1 = Fx.round(1, closer: Fx.bob, [Fx.alice: 50, Fx.bob: 0])
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: 40, Fx.bob: 0])
        let r3 = Fx.round(3, closer: Fx.bob, [Fx.alice: 5, Fx.bob: 0])
        for round in [r1, r2, r3] {
            _ = try repo.appendRound(round, toGame: Fx.gameA)
        }
        let before = try repo.game(id: Fx.gameA)
        #expect(before.computation.status == .inProgress)

        // Alice avait 60 à la manche 2 : 110 ⇒ la partie aurait dû finir avant la manche 3.
        let corrected = Fx.round(2, closer: Fx.bob, [Fx.alice: 60, Fx.bob: 0], id: r2.id)
        guard case .requiresDecision(let conflict) = try repo.replaceRound(corrected, inGame: Fx.gameA) else {
            Issue.record("Une décision explicite doit être demandée.")
            return
        }
        #expect(conflict.inconsistency.endingRoundIndex == 2)
        #expect(conflict.inconsistency.subsequentRoundIDs == [r3.id])
        #expect(try repo.game(id: Fx.gameA) == before)

        // Décision périmée (identifiants différents) : on redemande, rien n'est écrit.
        let stale = try repo.replaceRound(
            corrected,
            inGame: Fx.gameA,
            resolution: .deleteRoundsAfterEarlyEnd(confirmedRoundIDs: [UUID()])
        )
        guard case .requiresDecision = stale else {
            Issue.record("Une décision périmée ne doit rien supprimer.")
            return
        }
        #expect(try repo.game(id: Fx.gameA) == before)

        // Décision confirmée : correction + suppression en une seule transaction.
        let confirmed = try repo.replaceRound(
            corrected,
            inGame: Fx.gameA,
            resolution: .deleteRoundsAfterEarlyEnd(confirmedRoundIDs: [r3.id])
        )
        guard case .saved(let updated, let removed) = confirmed else {
            Issue.record("La décision confirmée doit être enregistrée.")
            return
        }
        #expect(removed == [before.rounds[2]])
        #expect(updated.rounds.map(\.id) == [r1.id, r2.id])
        #expect(updated.computation.status == .finished(roundIndex: 2, winnerIDs: [Fx.bob]))
        #expect(updated.computation.inconsistency == nil)
        #expect(try repo.game(id: Fx.gameA) == updated)
    }

    @Test("Suppression de la dernière manche, puis annulation par ré-ajout", arguments: RepositoryKind.allCases)
    func deleteLastRoundAndUndo(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 4, Fx.bob: 9]), toGame: Fx.gameA)
        _ = try repo.appendRound(Fx.round(2, closer: Fx.bob, [Fx.alice: 2, Fx.bob: 7]), toGame: Fx.gameA)
        let before = try repo.game(id: Fx.gameA)

        let deletion = try repo.deleteLastRound(ofGame: Fx.gameA)
        #expect(deletion.deletedRound == before.rounds[1])
        #expect(deletion.game.rounds == [before.rounds[0]])
        #expect(deletion.game.computation.totals == [Fx.alice: 4, Fx.bob: 9])
        #expect(try repo.game(id: Fx.gameA) == deletion.game)

        let undo = try repo.appendRound(deletion.deletedRound, toGame: Fx.gameA)
        #expect(undo.game.rounds == before.rounds)
        #expect(undo.game.computation == before.computation)

        _ = try repo.deleteLastRound(ofGame: Fx.gameA)
        _ = try repo.deleteLastRound(ofGame: Fx.gameA)
        let empty = repositoryError { _ = try repo.deleteLastRound(ofGame: Fx.gameA) }
        #expect(empty == GameRepositoryError.noRoundToDelete(gameID: Fx.gameA))
    }

    @Test("Terminer puis archiver : statuts, idempotence et lecture seule", arguments: RepositoryKind.allCases)
    func finishAndArchive(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 10, Fx.bob: 3]), toGame: Fx.gameA)

        let notOver = repositoryError { _ = try repo.finishGame(id: Fx.gameA) }
        #expect(notOver == GameRepositoryError.gameNotOver(Fx.gameA))

        _ = try repo.appendRound(Fx.round(2, closer: Fx.bob, [Fx.alice: 95, Fx.bob: 0]), toGame: Fx.gameA)
        let finished = try repo.finishGame(id: Fx.gameA)
        #expect(finished.lifecycle == .finished)
        #expect(finished.finishedAt != nil)
        #expect(finished.computation.status == .finished(roundIndex: 2, winnerIDs: [Fx.bob]))
        #expect(try repo.finishGame(id: Fx.gameA) == finished)
        #expect(try repo.activeGame() == nil)

        let readOnly = repositoryError { _ = try repo.deleteLastRound(ofGame: Fx.gameA) }
        #expect(readOnly == GameRepositoryError.gameNotActive(id: Fx.gameA, lifecycle: .finished))

        let archived = try repo.archiveGame(id: Fx.gameA)
        #expect(archived.lifecycle == .archived)
        #expect(!archived.isInterrupted)
        #expect(archived.finishedAt == finished.finishedAt)
        #expect(archived.rounds == finished.rounds)
        #expect(try repo.archiveGame(id: Fx.gameA) == archived)
        #expect(try repo.closedGames() == [.readable(archived)])

        let archivedFinish = repositoryError { _ = try repo.finishGame(id: Fx.gameA) }
        #expect(archivedFinish == GameRepositoryError.gameNotActive(id: Fx.gameA, lifecycle: .archived))
    }

    @Test("Suppression définitive, idempotente", arguments: RepositoryKind.allCases)
    func deleteGame(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]), toGame: Fx.gameA)

        #expect(try repo.deleteGame(id: Fx.gameA))
        #expect(try repo.deleteGame(id: Fx.gameA) == false)
        let notFound = repositoryError { _ = try repo.game(id: Fx.gameA) }
        #expect(notFound == GameRepositoryError.gameNotFound(Fx.gameA))
        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames().isEmpty)
    }

    @Test("Identifiant de manche déjà utilisé dans une autre partie ⇒ conflit", arguments: RepositoryKind.allCases)
    func roundIDReusedInAnotherGame(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        _ = try repo.appendRound(r1, toGame: Fx.gameA)
        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)

        let conflict = repositoryError { _ = try repo.appendRound(r1, toGame: Fx.gameB) }
        #expect(conflict == GameRepositoryError.identifierConflict(r1.id))
        #expect(try repo.game(id: Fx.gameB).rounds.isEmpty)
    }

    #if DEBUG
    @Test("Dépôt en mémoire : un échec d'écriture ne modifie rien et n'est jamais masqué")
    func inMemoryWriteFailure() throws {
        let repo = InMemoryGameRepository(now: { Date(timeIntervalSinceReferenceDate: 0) })
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let before = try repo.game(id: Fx.gameA)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])

        repo.simulatesWriteFailure = true
        let error = repositoryError { _ = try repo.appendRound(round, toGame: Fx.gameA) }
        #expect(error?.isWriteFailure == true)
        #expect(try repo.game(id: Fx.gameA) == before)

        repo.simulatesWriteFailure = false
        guard case .inserted = try repo.appendRound(round, toGame: Fx.gameA) else {
            Issue.record("La nouvelle tentative doit enregistrer la manche.")
            return
        }
    }
    #endif

    // MARK: Dates de manche (audit M5)

    @Test("Une correction marque la manche corrigée ; une correction identique ne change rien", arguments: RepositoryKind.allCases)
    func roundInfoTracksCorrections(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let r1 = Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 9])
        let afterAppend = try repo.appendRound(r1, toGame: Fx.gameA).game
        let initial = try #require(afterAppend.info(forRound: r1.id))
        #expect(!initial.wasCorrected)
        #expect(initial.createdAt == initial.modifiedAt)

        let corrected = Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 8], id: r1.id)
        guard case .saved(let updated, _) = try repo.replaceRound(corrected, inGame: Fx.gameA) else {
            Issue.record("La correction doit être enregistrée.")
            return
        }
        let info = try #require(updated.info(forRound: r1.id))
        #expect(info.wasCorrected)
        #expect(info.createdAt == initial.createdAt)
        #expect(info.modifiedAt > initial.createdAt)
        #expect(try repo.game(id: Fx.gameA) == updated)

        #expect(try repo.replaceRound(corrected, inGame: Fx.gameA) == .unchanged(updated))
        #expect(try repo.game(id: Fx.gameA).info(forRound: r1.id) == info)
    }

    // MARK: Réouverture (§4.6)

    @Test("Rouvrir une partie terminée permet de corriger puis de la clore à nouveau", arguments: RepositoryKind.allCases)
    func reopenAllowsCorrection(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let r1 = Fx.round(1, closer: Fx.bob, [Fx.alice: 100, Fx.bob: 0])
        _ = try repo.appendRound(r1, toGame: Fx.gameA)
        _ = try repo.finishGame(id: Fx.gameA)

        let reopened = try repo.reopenGame(id: Fx.gameA)
        #expect(reopened.lifecycle == .active)
        #expect(reopened.finishedAt == nil)
        #expect(try repo.activeGame() == reopened)
        #expect(try repo.reopenGame(id: Fx.gameA) == reopened)

        // Alice avait 50 : la partie reprend (le moteur la considère en cours).
        let corrected = Fx.round(1, closer: Fx.bob, [Fx.alice: 50, Fx.bob: 0], id: r1.id)
        guard case .saved(let updated, _) = try repo.replaceRound(corrected, inGame: Fx.gameA) else {
            Issue.record("La correction doit être enregistrée après réouverture.")
            return
        }
        #expect(!updated.isOver)
        let notOver = repositoryError { _ = try repo.finishGame(id: Fx.gameA) }
        #expect(notOver == GameRepositoryError.gameNotOver(Fx.gameA))
    }

    @Test("Réouverture refusée si une autre partie est active ou si la partie est archivée", arguments: RepositoryKind.allCases)
    func reopenRefusals(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 100, Fx.bob: 0]), toGame: Fx.gameA)
        let finished = try repo.finishGame(id: Fx.gameA)
        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)

        let busy = repositoryError { _ = try repo.reopenGame(id: Fx.gameA) }
        #expect(busy == GameRepositoryError.anotherGameActive(Fx.gameB))
        #expect(try repo.game(id: Fx.gameA) == finished)

        _ = try repo.archiveGame(id: Fx.gameA)
        let archived = repositoryError { _ = try repo.reopenGame(id: Fx.gameA) }
        #expect(archived == GameRepositoryError.invalidLifecycleTransition(id: Fx.gameA, from: .archived))
    }

    @Test("Archivage : date de fin posée pour une partie terminée, absente pour une interrompue", arguments: RepositoryKind.allCases)
    func archiveSetsFinishedAtOnlyWhenOver(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.bob, [Fx.alice: 100, Fx.bob: 0]), toGame: Fx.gameA)
        let over = try repo.archiveGame(id: Fx.gameA)
        #expect(over.finishedAt != nil)
        #expect(!over.isInterrupted)

        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)
        let interrupted = try repo.archiveGame(id: Fx.gameB)
        #expect(interrupted.finishedAt == nil)
        #expect(interrupted.isInterrupted)
    }

    // MARK: Textes saisis (audit M2)

    @Test("Titre : 80 caractères acceptés, 81 refusés, contrôles refusés", arguments: RepositoryKind.allCases)
    func titleValidation(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        let limit = GameWritePlanner.maxTitleLength
        #expect(limit == 80)

        let tooLong = repositoryError {
            _ = try repo.createGame(
                id: Fx.gameA,
                participants: Fx.players(2),
                rules: .classic,
                title: String(repeating: "t", count: limit + 1)
            )
        }
        #expect(tooLong == GameRepositoryError.invalidTitle(.tooLong(maxLength: 80)))
        for title in ["Soirée\nbis", "\u{0000}", "Soirée\u{2028}bis"] {
            let invalid = repositoryError {
                _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic, title: title)
            }
            #expect(invalid == GameRepositoryError.invalidTitle(.invalidCharacters))
        }
        #expect(try repo.activeGame() == nil)

        let accepted = try repo.createGame(
            id: Fx.gameA,
            participants: Fx.players(2),
            rules: .classic,
            title: String(repeating: "t", count: limit)
        )
        #expect(accepted.title?.count == limit)
    }

    @Test("Noms : 24 caractères acceptés, 25 refusés, retour à la ligne et NUL refusés", arguments: RepositoryKind.allCases)
    func participantNameValidation(kind: RepositoryKind) throws {
        let repo = try kind.make(clock: TestClock())
        func players(bobName: String) -> [Participant] {
            var players = Fx.players(2)
            players[1].displayName = bobName
            return players
        }

        let tooLong = repositoryError {
            _ = try repo.createGame(id: Fx.gameA, participants: players(bobName: String(repeating: "b", count: 25)), rules: .classic)
        }
        #expect(tooLong?.validationReason == .participantNameTooLong(participantID: Fx.bob, maxLength: 24))
        for name in ["Bo\nb", "\u{0000}Bob"] {
            let invalid = repositoryError {
                _ = try repo.createGame(id: Fx.gameA, participants: players(bobName: name), rules: .classic)
            }
            #expect(invalid?.validationReason == .participantNameHasInvalidCharacters(participantID: Fx.bob))
        }
        #expect(try repo.activeGame() == nil)

        let accepted = try repo.createGame(
            id: Fx.gameA,
            participants: players(bobName: String(repeating: "b", count: 24)),
            rules: .classic
        )
        #expect(accepted.participants[1].displayName.count == 24)
    }
}

// MARK: - Messages destinés à l'utilisateur (audit M4)

@Suite("Persistance : messages d'erreur affichables")
struct PersistenceErrorMessageTests {
    @Test("Message générique en français, sans nom, identifiant, valeur brute ni chemin")
    func userFacingMessagesAreGeneric() {
        let gameID = PersistenceFixtures.gameA
        let errors: [GameRepositoryError] = [
            .validation(.emptyParticipantName(participantID: gameID)),
            .invalidTitle(.tooLong(maxLength: 80)),
            .gameNotFound(gameID),
            .gameNotActive(id: gameID, lifecycle: .finished),
            .invalidLifecycleTransition(id: gameID, from: .archived),
            .anotherGameActive(gameID),
            .gameNotOver(gameID),
            .noRoundToDelete(gameID: gameID),
            .identifierConflict(gameID),
            .corruptedData(gameID: gameID, .unknownLifecycle("zombie")),
            .storageFailure(.setup, message: "/private/var/mobile/Alice/TableScore.store"),
            .storageFailure(.read, message: "Alice"),
            .storageFailure(.write, message: "Alice"),
            .storageFailure(.encoding, message: "Alice"),
        ]
        for error in errors {
            let message = error.userFacingMessage
            #expect(!message.isEmpty)
            #expect(!message.contains("/"))
            #expect(!message.contains("Alice"))
            #expect(!message.contains("zombie"))
            #expect(!message.contains(gameID.uuidString))
        }
    }

    @Test("Valeur brute de statut tronquée à 32 caractères dans le diagnostic")
    func unknownLifecycleIsTruncated() {
        let raw = String(repeating: "x", count: 500)
        #expect(PersistedDataCorruption.truncatedUnknownLifecycle(raw) == .unknownLifecycle(String(repeating: "x", count: 32)))
        #expect(PersistedDataCorruption.truncatedUnknownLifecycle("zombie") == .unknownLifecycle("zombie"))
    }
}
