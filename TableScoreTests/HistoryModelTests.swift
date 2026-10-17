#if DEBUG
import Foundation
import Testing
import TableScoreKit
@testable import TableScore

// MARK: - Doublures

/// Horloge déterministe (chaque lecture avance d'une minute) : rend `wasCorrected` observable.
@MainActor
private final class HistoryTestClock {
    private var current = Date(timeIntervalSinceReferenceDate: 820_000_000)

    func next() -> Date {
        current = current.addingTimeInterval(60)
        return current
    }
}

/// Dépôt à une seule partie, initialisé avec une `SavedGame` arbitraire : permet de reproduire une
/// fin anticipée **déjà enregistrée** (données anciennes), impossible à créer via l'API publique.
/// Mêmes décisions que les dépôts réels (`GameWritePlanner`) ; échec de suppression simulable.
@MainActor
private final class SingleGameRepository: GameRepository {
    private(set) var stored: SavedGame
    /// `nil` : aucune panne ; sinon nombre de suppressions encore autorisées avant échec.
    var remainingSuccessfulDeletions: Int?
    private(set) var deletionCount = 0
    private let clock: HistoryTestClock

    init(game: SavedGame) {
        stored = game
        clock = HistoryTestClock()
    }

    func replaceStored(_ game: SavedGame) {
        stored = game
    }

    func activeGame() throws(GameRepositoryError) -> SavedGame? {
        stored.lifecycle == .active ? stored : nil
    }

    func game(id: UUID) throws(GameRepositoryError) -> SavedGame {
        guard id == stored.id else { throw GameRepositoryError.gameNotFound(id) }
        return stored
    }

    func closedGames() throws(GameRepositoryError) -> [GameListing] {
        stored.lifecycle == .active ? [] : [.readable(stored)]
    }

    func createGame(
        id: UUID, participants: [Participant], rules: GameRules, title: String?
    ) throws(GameRepositoryError) -> SavedGame {
        throw GameRepositoryError.storageFailure(.write, message: "Non pris en charge par la doublure.")
    }

    func appendRound(_ round: RoundInput, toGame gameID: UUID) throws(GameRepositoryError) -> AppendRoundOutcome {
        let current = try game(id: gameID)
        let plan = try GameWritePlanner.planAppend(round, to: current, roundIDUsedElsewhere: false, at: clock.next())
        switch plan {
        case .alreadySaved:
            return .alreadySaved(current)
        case .insert(let updated):
            stored = updated
            return .inserted(updated)
        }
    }

    func replaceRound(
        _ round: RoundInput, inGame gameID: UUID, resolution: EarlyEndResolution
    ) throws(GameRepositoryError) -> RoundReplacementOutcome {
        let current = try game(id: gameID)
        let plan = try GameWritePlanner.planReplace(round, in: current, resolution: resolution, at: clock.next())
        switch plan {
        case .unchanged:
            return .unchanged(current)
        case .requiresDecision(let conflict):
            return .requiresDecision(conflict)
        case .write(let updated, _, let removedRounds):
            stored = updated
            return .saved(updated, removedRounds: removedRounds)
        }
    }

    func deleteLastRound(ofGame gameID: UUID) throws(GameRepositoryError) -> RoundDeletion {
        if let remaining = remainingSuccessfulDeletions {
            guard remaining > 0 else {
                throw GameRepositoryError.storageFailure(.write, message: "Échec simulé.")
            }
            remainingSuccessfulDeletions = remaining - 1
        }
        let deletion = try GameWritePlanner.planDeleteLast(of: try game(id: gameID), at: clock.next())
        stored = deletion.game
        deletionCount += 1
        return deletion
    }

    func finishGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        guard let updated = try GameWritePlanner.planFinish(try game(id: id), at: clock.next()) else { return stored }
        stored = updated
        return updated
    }

    func reopenGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        let current = try game(id: id)
        guard let updated = try GameWritePlanner.planReopen(current, otherActiveGameID: nil, at: clock.next()) else {
            return current
        }
        stored = updated
        return updated
    }

    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        guard let updated = GameWritePlanner.planArchive(try game(id: id), at: clock.next()) else { return stored }
        stored = updated
        return updated
    }

    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool { false }
}

// MARK: - Tests

@Suite("Historique : affichage, correction, suppression, incohérence")
@MainActor
struct HistoryModelTests {
    private typealias Key = UITestSeed.GameKey

    // MARK: Données

    private func seededRepository() throws -> InMemoryGameRepository {
        let clock = HistoryTestClock()
        let repository = InMemoryGameRepository(now: { clock.next() })
        try UITestSeed.withHistory.apply(to: repository)
        return repository
    }

    private func historyModel(_ repository: any GameRepository, _ gameID: UUID) -> HistoryModel {
        let model = HistoryModel(gameID: gameID, repository: repository)
        model.load()
        return model
    }

    private func row(_ model: HistoryModel, index: Int) throws -> HistoryModel.RoundRow {
        try #require(model.rows.first(where: { $0.index == index }))
    }

    /// Identifiant fixe `4157…` (« hist »), sans force-unwrap.
    private static func fixedID(_ n: UInt8) -> UUID {
        UUID(uuid: (0x41, 0x57, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, n))
    }

    private static func points(_ ids: [UUID], _ scores: [Int]) -> [RoundEntry] {
        zip(ids, scores).map { RoundEntry.points($0, rawScore: $1) }
    }

    /// Alice/Bob : la partie se termine à la manche 2 (Alice 105) ; manches 3 et 4 jouées ensuite.
    private static func inconsistentGame(lifecycle: GameLifecycle = .active) throws -> SavedGame {
        let alice = Participant(id: fixedID(1), displayName: "Alice", displayOrder: 0)
        let bob = Participant(id: fixedID(2), displayName: "Bob", displayOrder: 1)
        let ids = [alice.id, bob.id]
        let rounds = [
            RoundInput(id: fixedID(11), index: 1, closingParticipantID: bob.id, entries: points(ids, [60, 4])),
            RoundInput(id: fixedID(12), index: 2, closingParticipantID: bob.id, entries: points(ids, [45, 8])),
            RoundInput(id: fixedID(13), index: 3, closingParticipantID: alice.id, entries: points(ids, [1, 5])),
            RoundInput(id: fixedID(14), index: 4, closingParticipantID: bob.id, entries: points(ids, [3, 2])),
        ]
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000)
        return try SavedGame(
            id: fixedID(0xA0),
            title: nil,
            lifecycle: lifecycle,
            rules: .classic,
            participants: [alice, bob],
            rounds: rounds,
            roundInfo: [:],
            createdAt: date,
            updatedAt: date,
            finishedAt: lifecycle == .active ? nil : date,
            archivedAt: lifecycle == .archived ? date : nil
        )
    }

    // MARK: Affichage (seed withHistory)

    @Test("withHistory : manches de la plus récente à la plus ancienne, dernière identifiée")
    func rowsOrder() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)
        #expect(model.loadError == nil)
        #expect(model.lifecycle == .active)
        #expect(model.rows.map(\.index) == [4, 3, 2, 1])
        #expect(model.rows.filter(\.isLast).map(\.index) == [4])
        #expect(model.lastRound?.index == 4)
        #expect(model.canDeleteLastRound)
        #expect(model.inconsistency == nil)
        #expect(model.rows.allSatisfy({ !$0.isCorrected && !$0.isAfterGameEnd && !$0.isEndingRound }))
    }

    @Test("withHistory : bruts, retenus et cumuls fournis par le moteur")
    func rawEffectiveAndTotals() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)
        let expected: [(index: Int, raw: [Int], effective: [Int], totals: [Int])] = [
            (1, [10, 24, 10, 15], [20, 24, 10, 15], [20, 24, 10, 15]),
            (2, [5, 12, 18, 30], [5, 24, 18, 30], [25, 48, 28, 45]),
            (3, [7, -2, 0, 11], [7, -2, 0, 11], [32, 46, 28, 56]),
            (4, [9, 14, 6, -3], [9, 14, 6, -3], [41, 60, 34, 53]),
        ]
        for item in expected {
            let current = try row(model, index: item.index)
            #expect(current.players.map(\.name) == ["Alice", "Bob", "Chloé", "Dimitri"])
            #expect(current.players.map(\.position) == [0, 1, 2, 3])
            #expect(current.players.map(\.rawScore) == item.raw, "manche \(item.index)")
            #expect(current.players.map(\.effectiveScore) == item.effective, "manche \(item.index)")
            #expect(current.players.map(\.totalAfterRound) == item.totals.map(Optional.some), "manche \(item.index)")
        }
    }

    @Test("withHistory : clôturant, doublement et raison indiqués")
    func closerAndDoubling() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)

        let first = try row(model, index: 1)
        #expect(first.closerName == "Alice")
        #expect(first.isCloserDoubled)
        #expect(first.closerNote == "score doublé : égalité avec Chloé")
        #expect(first.players.map(\.isClosing) == [true, false, false, false])
        #expect(first.players.map(\.isDoubled) == [true, false, false, false])

        let second = try row(model, index: 2)
        #expect(second.closerName == "Bob")
        #expect(second.isCloserDoubled)
        #expect(second.closerNote == "score doublé : Alice a fait moins")
        #expect(second.players.map(\.isDoubled) == [false, true, false, false])

        let third = try row(model, index: 3)
        #expect(!third.isCloserDoubled)
        #expect(third.closerNote == "zéro, jamais doublé")
        #expect(third.players.allSatisfy({ !$0.isDoubled }))

        let fourth = try row(model, index: 4)
        #expect(!fourth.isCloserDoubled)
        #expect(fourth.closerNote == "score négatif, jamais doublé")
        #expect(fourth.displayedCloserNote == "Score négatif, jamais doublé")
    }

    @Test("VoiceOver : une phrase par manche avec clôturant, doublement et cumuls")
    func spokenSummary() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)
        let first = try row(model, index: 1).accessibilityLabel
        #expect(first.hasPrefix("Manche 1, Alice a terminé, score doublé : égalité avec Chloé."))
        #expect(first.contains("Alice 10 doublé à 20, total 20."))
        #expect(first.contains("Bob 24, total 24."))
        let fourth = try row(model, index: 4).accessibilityLabel
        #expect(fourth.contains("Dimitri moins 3, total 53."))
        #expect(fourth.contains("Alice 9, total 41."))
    }

    @Test("Liste de noms en français")
    func frenchList() {
        #expect(HistoryModel.frenchList([]) == "")
        #expect(HistoryModel.frenchList(["Alice"]) == "Alice")
        #expect(HistoryModel.frenchList(["Alice", "Bob"]) == "Alice et Bob")
        #expect(HistoryModel.frenchList(["Alice", "Bob", "Chloé"]) == "Alice, Bob et Chloé")
    }

    @Test("Partie sans manche : liste vide, rien à supprimer")
    func emptyGame() throws {
        let repository = InMemoryGameRepository()
        let players = [
            Participant(id: Self.fixedID(1), displayName: "Alice", displayOrder: 0),
            Participant(id: Self.fixedID(2), displayName: "Bob", displayOrder: 1),
        ]
        let game = try repository.createGame(id: Self.fixedID(0xB0), participants: players, rules: .classic)
        let model = historyModel(repository, game.id)
        #expect(model.hasLoaded)
        #expect(model.loadError == nil)
        #expect(model.rows.isEmpty)
        #expect(!model.canDeleteLastRound)
        #expect(!model.deleteLastRound())
    }

    @Test("Partie introuvable : message lisible, aucune ligne")
    func unknownGame() {
        let model = historyModel(InMemoryGameRepository(), Self.fixedID(0xFF))
        #expect(model.loadError != nil)
        #expect(model.rows.isEmpty)
        #expect(model.requestEdit(roundID: Self.fixedID(1)) == .unavailable)
    }

    // MARK: Correction (§10 n° 11)

    @Test("Toucher une manche d'une partie active : correction directe")
    func editActiveGame() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)
        let roundID = Key.historyActive.roundID(index: 1)
        #expect(model.requestEdit(roundID: roundID) == .present(roundID: roundID))
        #expect(model.pendingReopenRoundID == nil)
        #expect(model.requestEdit(roundID: Self.fixedID(0x99)) == .unavailable)
    }

    @Test("Correction d'une ancienne manche : recalcul intégral et mention « corrigée »")
    func correctionRecomputesFollowingRounds() throws {
        let repository = try seededRepository()
        let key = Key.historyActive
        let ids = (0..<4).map { key.participantID(position: $0) }
        // Chloé 10 → 11 : Alice (10) devient seule plus petite, plus de doublement.
        let corrected = RoundInput(
            id: key.roundID(index: 1),
            index: 1,
            closingParticipantID: ids[0],
            entries: Self.points(ids, [10, 24, 11, 15])
        )
        let outcome = try repository.replaceRound(corrected, inGame: key.id)
        guard case .saved = outcome else {
            Issue.record("La correction aurait dû être enregistrée : \(outcome)")
            return
        }

        let model = historyModel(repository, key.id)
        let first = try row(model, index: 1)
        #expect(first.isCorrected)
        #expect(!first.isCloserDoubled)
        #expect(first.closerNote == "seul plus petit score, pas de pénalité")
        #expect(first.players.map(\.effectiveScore) == [10, 24, 11, 15])
        #expect(try row(model, index: 2).isCorrected == false)
        #expect(try row(model, index: 4).players.map(\.totalAfterRound) == [31, 60, 35, 53])
        #expect(try row(model, index: 1).accessibilityLabel.contains("Manche corrigée."))
    }

    // MARK: Partie close

    @Test("Partie terminée : réouverture confirmée requise avant la correction")
    func finishedGameRequiresReopen() throws {
        let repository = InMemoryGameRepository()
        try UITestSeed.tieEnd.apply(to: repository)
        let gameID = UITestSeed.tieEnd.activeGameID
        _ = try repository.finishGame(id: gameID)
        let model = historyModel(repository, gameID)
        #expect(model.lifecycle == .finished)
        #expect(!model.canDeleteLastRound)
        #expect(model.lifecycleNote != nil)

        let roundID = Key.tieEnd.roundID(index: 1)
        #expect(model.requestEdit(roundID: roundID) == .needsReopen)
        #expect(model.pendingReopenRoundID == roundID)
        // Rien n'est écrit tant que l'utilisateur n'a pas confirmé.
        #expect(try repository.game(id: gameID).lifecycle == .finished)

        model.cancelReopen()
        #expect(model.pendingReopenRoundID == nil)
        #expect(try repository.game(id: gameID).lifecycle == .finished)

        #expect(model.requestEdit(roundID: roundID) == .needsReopen)
        #expect(model.confirmReopen(roundID: roundID) == roundID)
        #expect(model.pendingReopenRoundID == nil)
        #expect(model.actionError == nil)
        #expect(try repository.game(id: gameID).lifecycle == .active)
        #expect(model.lifecycle == .active)
        #expect(model.requestEdit(roundID: roundID) == .present(roundID: roundID))
    }

    @Test("Réouverture refusée si une autre partie est en cours : message, aucune modification")
    func reopenRefusedWhenAnotherGameIsActive() throws {
        let repository = try seededRepository()
        let gameID = Key.historyFinished.id
        let model = historyModel(repository, gameID)
        let roundID = Key.historyFinished.roundID(index: 1)
        #expect(model.requestEdit(roundID: roundID) == .needsReopen)
        #expect(model.confirmReopen(roundID: roundID) == nil)
        let message = try #require(model.actionError)
        #expect(message.contains("Une autre partie est en cours"))
        #expect(try repository.game(id: gameID).lifecycle == .finished)
        #expect(try repository.activeGame()?.id == Key.historyActive.id)
    }

    @Test("Partie interrompue : lecture seule")
    func archivedGameIsReadOnly() throws {
        let model = historyModel(try seededRepository(), Key.historyInterrupted.id)
        #expect(model.lifecycle == .archived)
        #expect(!model.isEditable)
        #expect(!model.canDeleteLastRound)
        #expect(model.rows.count == 1)
        #expect(model.requestEdit(roundID: Key.historyInterrupted.roundID(index: 1)) == .unavailable)
    }

    // MARK: Suppression de la dernière manche + annulation

    @Test("Supprimer la dernière manche puis annuler restaure la même manche et les mêmes totaux")
    func deleteLastRoundThenUndo() throws {
        let repository = try seededRepository()
        let gameID = Key.historyActive.id
        let before = try repository.game(id: gameID)
        let model = historyModel(repository, gameID)

        #expect(model.deleteLastRound())
        let deletion = try #require(model.undoableDeletion)
        #expect(deletion.index == 4)
        #expect(deletion.round == before.rounds.last)
        #expect(deletion.bannerText == "Manche 4 supprimée")
        #expect(model.rows.map(\.index) == [3, 2, 1])
        #expect(try repository.game(id: gameID).rounds.count == 3)

        #expect(model.undoDeletion())
        #expect(model.undoableDeletion == nil)
        let after = try repository.game(id: gameID)
        #expect(after.rounds == before.rounds)
        #expect(after.computation == before.computation)
        #expect(model.rows.map(\.index) == [4, 3, 2, 1])
        #expect(try row(model, index: 4).players.map(\.totalAfterRound) == [41, 60, 34, 53])

        // Idempotence : second appel sans effet, ré-ajout direct reconnu comme déjà enregistré.
        #expect(!model.undoDeletion())
        let replay = try repository.appendRound(deletion.round, toGame: gameID)
        guard case .alreadySaved = replay else {
            Issue.record("Le ré-ajout de la même manche doit être idempotent : \(replay)")
            return
        }
        #expect(try repository.game(id: gameID).rounds == before.rounds)
    }

    @Test("L'annulation disparaît si l'historique change par ailleurs")
    func undoClearedAfterAnotherChange() throws {
        let repository = try seededRepository()
        let key = Key.historyActive
        let model = historyModel(repository, key.id)
        #expect(model.deleteLastRound())
        #expect(model.undoableDeletion != nil)

        // Une nouvelle manche 4 (autre identifiant) est saisie depuis le tableau des scores.
        let ids = (0..<4).map { key.participantID(position: $0) }
        let newRound = RoundInput(
            id: Self.fixedID(0x44),
            index: 4,
            closingParticipantID: ids[1],
            entries: Self.points(ids, [5, 1, 7, 9])
        )
        _ = try repository.appendRound(newRound, toGame: key.id)
        model.load()
        #expect(model.undoableDeletion == nil)
        #expect(!model.undoDeletion())
        #expect(try repository.game(id: key.id).rounds.last?.id == newRound.id)
    }

    @Test("Toucher une manche met fin à la possibilité d'annuler")
    func editClearsUndo() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)
        #expect(model.deleteLastRound())
        let roundID = Key.historyActive.roundID(index: 1)
        #expect(model.requestEdit(roundID: roundID) == .present(roundID: roundID))
        #expect(model.undoableDeletion == nil)
    }

    @Test("Échec d'écriture : message affiché, rien n'est supprimé")
    func deletionFailureIsReported() throws {
        let repository = try seededRepository()
        let model = historyModel(repository, Key.historyActive.id)
        repository.simulatesWriteFailure = true
        #expect(!model.deleteLastRound())
        #expect(model.actionError != nil)
        #expect(model.undoableDeletion == nil)
        #expect(try repository.game(id: Key.historyActive.id).rounds.count == 4)
        #expect(model.rows.count == 4)
    }

    // MARK: Incohérence déjà enregistrée (§4.6, §10 n° 12)

    @Test("Fin anticipée enregistrée : signalée, aucune suppression implicite")
    func inconsistencyIsReported() throws {
        let repository = SingleGameRepository(game: try Self.inconsistentGame())
        let model = historyModel(repository, Self.fixedID(0xA0))
        let notice = try #require(model.inconsistency)
        #expect(notice.endingRoundIndex == 2)
        #expect(notice.subsequentRoundIndices == [3, 4])
        #expect(notice.subsequentRoundIDs == [Self.fixedID(13), Self.fixedID(14)])
        #expect(notice.actionTitle == "Supprimer les manches 3 et 4")
        #expect(notice.confirmationTitle == "Supprimer définitivement 2 manches ?")
        #expect(notice.message.contains("manche 2"))
        #expect(!notice.requiresReopen)
        #expect(model.canResolveInconsistency)
        // La suppression unitaire (annulable) est remplacée par la résolution explicite.
        #expect(!model.canDeleteLastRound)
        #expect(try row(model, index: 2).isEndingRound)
        #expect(try row(model, index: 3).isAfterGameEnd)
        #expect(try row(model, index: 4).isAfterGameEnd)
        let firstRow = try row(model, index: 1)
        #expect(!firstRow.isAfterGameEnd)
        #expect(repository.stored.rounds.count == 4)
        #expect(repository.deletionCount == 0)
    }

    @Test("Résolution confirmée : seules les manches postérieures sont supprimées")
    func resolveDeletesOnlySubsequentRounds() throws {
        let original = try Self.inconsistentGame()
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)

        #expect(model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(repository.deletionCount == 2)
        #expect(repository.stored.rounds == Array(original.rounds.prefix(2)))
        #expect(repository.stored.computation.inconsistency == nil)
        #expect(model.inconsistency == nil)
        #expect(model.actionError == nil)
        #expect(model.rows.map(\.index) == [2, 1])
        #expect(model.undoableDeletion == nil)
    }

    @Test("Résolution sur une partie close : réouverture puis suppression")
    func resolveOnFinishedGameReopensFirst() throws {
        let original = try Self.inconsistentGame(lifecycle: .finished)
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)
        #expect(notice.requiresReopen)
        #expect(notice.confirmationMessage.contains("La partie sera rouverte."))

        #expect(model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(repository.stored.lifecycle == .active)
        #expect(repository.stored.rounds == Array(original.rounds.prefix(2)))
        #expect(model.inconsistency == nil)
    }

    @Test("Échec en cours de résolution : erreur affichée, aucune manche antérieure touchée")
    func partialResolutionFailure() throws {
        let original = try Self.inconsistentGame()
        let repository = SingleGameRepository(game: original)
        repository.remainingSuccessfulDeletions = 1
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)

        #expect(model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(model.actionError != nil)
        #expect(repository.stored.rounds == Array(original.rounds.prefix(3)))
        // L'incohérence restante reste signalée, avec la seule manche 3.
        #expect(model.inconsistency?.subsequentRoundIndices == [3])
    }

    @Test("Décision périmée (données modifiées depuis l'affichage) : rien n'est supprimé")
    func staleDecisionDeletesNothing() throws {
        let original = try Self.inconsistentGame()
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)

        // Entre-temps, la manche 4 a disparu : l'ensemble confirmé ne correspond plus.
        let changed = try original.replacingRounds(
            Array(original.rounds.prefix(3)),
            roundInfo: original.roundInfo,
            updatedAt: original.updatedAt
        )
        repository.replaceStored(changed)

        #expect(!model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(repository.deletionCount == 0)
        #expect(repository.stored.rounds.count == 3)
        #expect(model.actionError != nil)
        #expect(model.inconsistency?.subsequentRoundIndices == [3])
    }

    @Test("Partie interrompue incohérente : signalée mais non modifiable")
    func archivedInconsistencyIsReadOnly() throws {
        let original = try Self.inconsistentGame(lifecycle: .archived)
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)
        #expect(!model.canResolveInconsistency)
        #expect(!model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(repository.deletionCount == 0)
        #expect(repository.stored.rounds.count == 4)
    }
}
#endif
