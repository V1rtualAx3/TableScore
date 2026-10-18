#if DEBUG
import Foundation
import SwiftData
import Testing
import TableScoreKit
@testable import TableScore

/// `GameRepository.deleteRoundsAfterEarlyEnd` (§4.6, audit sécurité M3) : résolution **atomique**
/// d'une fin anticipée déjà enregistrée, identique pour SwiftData et le dépôt en mémoire.
///
/// Une telle incohérence ne peut pas être créée par l'API publique (la correction la refuse) :
/// elle est injectée telle quelle (enregistrements SwiftData bruts / `insertUncheckedForTesting`),
/// comme des données anciennes.
@Suite("Persistance : suppression atomique des manches après une fin anticipée")
@MainActor
struct PersistenceEarlyEndTests {
    private typealias Fx = PersistenceFixtures

    /// Dépôt + interrupteur d'échec de sauvegarde (SwiftData) ou d'écriture (mémoire).
    private struct Harness {
        let repository: any GameRepository
        let failNextWrite: @MainActor () -> Void
        let restoreWrites: @MainActor () -> Void
    }

    private static let r1 = Fx.uuid(0x11)
    private static let r2 = Fx.uuid(0x12)
    private static let r3 = Fx.uuid(0x13)
    private static let r4 = Fx.uuid(0x14)
    private static let createdAt = Date(timeIntervalSinceReferenceDate: 790_000_000)

    /// Alice/Bob : Alice atteint 105 à la manche 2 ; manches 3 et 4 jouées ensuite.
    private static func inconsistentGame(lifecycle: GameLifecycle) throws -> SavedGame {
        let rounds = [
            Fx.round(1, closer: Fx.bob, [Fx.alice: 60, Fx.bob: 4], id: r1),
            Fx.round(2, closer: Fx.bob, [Fx.alice: 45, Fx.bob: 8], id: r2),
            Fx.round(3, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 5], id: r3),
            Fx.round(4, closer: Fx.bob, [Fx.alice: 3, Fx.bob: 2], id: r4),
        ]
        let info = Dictionary(uniqueKeysWithValues: rounds.map {
            ($0.id, SavedRoundInfo(createdAt: createdAt, modifiedAt: createdAt))
        })
        return try SavedGame(
            id: Fx.gameA,
            title: nil,
            lifecycle: lifecycle,
            rules: .classic,
            participants: Fx.players(2),
            rounds: rounds,
            roundInfo: info,
            createdAt: createdAt,
            updatedAt: createdAt,
            finishedAt: lifecycle == .active ? nil : createdAt,
            archivedAt: lifecycle == .archived ? createdAt : nil
        )
    }

    private func harness(_ kind: RepositoryKind, storing game: SavedGame) throws -> Harness {
        let clock = TestClock()
        switch kind {
        case .swiftData:
            let container = try PersistenceController.makeContainer(storage: .inMemory)
            try Self.insertRaw(game, into: container)
            let failures = SaveFailureSwitch()
            let repository = SwiftDataGameRepository(
                container: container,
                now: { clock.next() },
                saveHandler: { try failures.save($0) }
            )
            return Harness(
                repository: repository,
                failNextWrite: { failures.failNextSave = true },
                restoreWrites: { failures.failNextSave = false }
            )
        case .inMemory:
            let repository = InMemoryGameRepository(now: { clock.next() })
            repository.insertUncheckedForTesting(game)
            return Harness(
                repository: repository,
                failNextWrite: { repository.simulatesWriteFailure = true },
                restoreWrites: { repository.simulatesWriteFailure = false }
            )
        }
    }

    /// Écrit la partie telle quelle, sans passer par les contrôles du dépôt.
    private static func insertRaw(_ game: SavedGame, into container: ModelContainer) throws {
        let context = ModelContext(container)
        let record = GameRecord(
            gameID: game.id,
            title: game.title,
            lifecycleRaw: game.lifecycle.rawValue,
            rulesPayload: try RecordMapper.rulesPayload(of: game.rules),
            createdAt: game.createdAt,
            updatedAt: game.updatedAt,
            finishedAt: game.finishedAt,
            archivedAt: game.archivedAt
        )
        context.insert(record)
        for participant in game.participants {
            let participantRecord = ParticipantRecord(
                participantID: participant.id,
                displayName: participant.displayName,
                displayOrder: participant.displayOrder
            )
            context.insert(participantRecord)
            participantRecord.game = record
        }
        for round in game.rounds {
            let info = game.info(forRound: round.id)
            let roundRecord = RoundRecord(
                roundID: round.id,
                roundIndex: round.index,
                closingParticipantID: round.closingParticipantID,
                entriesPayload: try RecordMapper.entriesPayload(of: round),
                createdAt: info?.createdAt ?? game.createdAt,
                modifiedAt: info?.modifiedAt ?? game.createdAt
            )
            context.insert(roundRecord)
            roundRecord.game = record
        }
        try context.save()
    }

    // MARK: Succès

    @Test("Partie active : seules les manches postérieures sont supprimées, statut inchangé", arguments: RepositoryKind.allCases)
    func deletesOnlySubsequentRounds(kind: RepositoryKind) throws {
        let original = try Self.inconsistentGame(lifecycle: .active)
        let repo = try harness(kind, storing: original).repository
        #expect(try repo.game(id: Fx.gameA).computation.inconsistency?.subsequentRoundIDs == [Self.r3, Self.r4])

        let updated = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: [Self.r4, Self.r3])
        #expect(updated.rounds == Array(original.rounds.prefix(2)))
        #expect(updated.computation.inconsistency == nil)
        #expect(updated.computation.status == .finished(roundIndex: 2, winnerIDs: [Fx.bob]))
        #expect(updated.lifecycle == .active)
        #expect(updated.finishedAt == nil)
        // Les manches conservées gardent leurs dates (non marquées corrigées).
        #expect(updated.info(forRound: Self.r1) == original.info(forRound: Self.r1))
        #expect(updated.info(forRound: Self.r3) == nil)
        #expect(try repo.game(id: Fx.gameA) == updated)
        #expect(try repo.activeGame() == updated)
    }

    @Test("Partie terminée : reste terminée (jamais rouverte), date de fin conservée", arguments: RepositoryKind.allCases)
    func finishedGameStaysFinished(kind: RepositoryKind) throws {
        let original = try Self.inconsistentGame(lifecycle: .finished)
        let repo = try harness(kind, storing: original).repository

        let updated = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: [Self.r3, Self.r4])
        #expect(updated.lifecycle == .finished)
        #expect(updated.finishedAt == original.finishedAt)
        #expect(updated.rounds.map(\.id) == [Self.r1, Self.r2])
        #expect(updated.isOver)
        #expect(try repo.game(id: Fx.gameA) == updated)
        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames() == [.readable(updated)])
    }

    // MARK: Refus sans écriture

    @Test("Décision périmée, partielle, élargie ou dupliquée : refus, rien n'est écrit", arguments: RepositoryKind.allCases)
    func staleDecisionsWriteNothing(kind: RepositoryKind) throws {
        let repo = try harness(kind, storing: try Self.inconsistentGame(lifecycle: .active)).repository
        let before = try repo.game(id: Fx.gameA)
        let attempts: [[UUID]] = [
            [],
            [Self.r4],
            [Self.r2, Self.r3, Self.r4],
            [Self.r3, Self.r4, Self.r4],
            [Self.r3, UUID()],
        ]
        for confirmed in attempts {
            let error = repositoryError {
                _ = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: confirmed)
            }
            #expect(error == GameRepositoryError.staleEarlyEndDecision(gameID: Fx.gameA), "confirmés : \(confirmed)")
            #expect(try repo.game(id: Fx.gameA) == before)
        }
    }

    @Test("Aucune incohérence : refus, rien n'est écrit", arguments: RepositoryKind.allCases)
    func noInconsistencyIsRefused(kind: RepositoryKind) throws {
        let original = try Self.inconsistentGame(lifecycle: .active)
        let consistent = try original.replacingRounds(
            Array(original.rounds.prefix(2)),
            roundInfo: original.roundInfo,
            updatedAt: original.updatedAt
        )
        let repo = try harness(kind, storing: consistent).repository
        let error = repositoryError {
            _ = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: [Self.r3])
        }
        #expect(error == GameRepositoryError.staleEarlyEndDecision(gameID: Fx.gameA))
        #expect(try repo.game(id: Fx.gameA) == consistent)
    }

    @Test("Partie interrompue (lecture seule) ou inconnue : refus", arguments: RepositoryKind.allCases)
    func archivedOrUnknownIsRefused(kind: RepositoryKind) throws {
        let archived = try Self.inconsistentGame(lifecycle: .archived)
        let repo = try harness(kind, storing: archived).repository
        let before = try repo.game(id: Fx.gameA)

        let archivedError = repositoryError {
            _ = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: [Self.r3, Self.r4])
        }
        #expect(archivedError == GameRepositoryError.gameNotActive(id: Fx.gameA, lifecycle: .archived))
        #expect(try repo.game(id: Fx.gameA) == before)

        let unknownError = repositoryError {
            _ = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameB, confirmedRoundIDs: [Self.r3, Self.r4])
        }
        #expect(unknownError == GameRepositoryError.gameNotFound(Fx.gameB))
    }

    // MARK: Échec de sauvegarde

    @Test("Échec de sauvegarde : aucune manche supprimée, erreur remontée, nouvelle tentative possible", arguments: RepositoryKind.allCases)
    func failedSaveDeletesNothing(kind: RepositoryKind) throws {
        let setup = try harness(kind, storing: try Self.inconsistentGame(lifecycle: .finished))
        let repo = setup.repository
        let before = try repo.game(id: Fx.gameA)

        setup.failNextWrite()
        let error = repositoryError {
            _ = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: [Self.r3, Self.r4])
        }
        #expect(error?.isWriteFailure == true)
        #expect(try repo.game(id: Fx.gameA) == before)
        #expect(try repo.game(id: Fx.gameA).rounds.count == 4)

        setup.restoreWrites()
        let updated = try repo.deleteRoundsAfterEarlyEnd(gameID: Fx.gameA, confirmedRoundIDs: [Self.r3, Self.r4])
        #expect(updated.rounds.count == 2)
        #expect(updated.lifecycle == .finished)
    }

    // MARK: Plan pur

    @Test("Plan pur : manches supprimées listées, aucune donnée inventée")
    func plannerIsPure() throws {
        let game = try Self.inconsistentGame(lifecycle: .active)
        let date = Date(timeIntervalSinceReferenceDate: 795_000_000)
        let plan = try GameWritePlanner.planDeleteRoundsAfterEarlyEnd(
            game,
            confirmedRoundIDs: [Self.r3, Self.r4],
            at: date
        )
        #expect(plan.removedRounds == Array(game.rounds.suffix(2)))
        #expect(plan.game.rounds == Array(game.rounds.prefix(2)))
        #expect(plan.game.updatedAt == date)
        #expect(plan.game.lifecycle == .active)
        // Déterministe : même entrée, même plan.
        let again = try GameWritePlanner.planDeleteRoundsAfterEarlyEnd(
            game,
            confirmedRoundIDs: [Self.r3, Self.r4],
            at: date
        )
        #expect(again == plan)
    }
}
#endif
