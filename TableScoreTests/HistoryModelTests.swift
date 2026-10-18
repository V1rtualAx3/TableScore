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
/// Mêmes décisions que les dépôts réels (`GameWritePlanner`) ; échecs d'écriture simulables.
@MainActor
private final class SingleGameRepository: GameRepository {
    private(set) var stored: SavedGame
    /// Toute écriture échoue (rien n'est modifié) tant que la valeur est vraie.
    var failsWrites = false
    /// La prochaine correction (`replaceRound`) échoue, les autres écritures réussissent.
    var failsNextReplace = false
    /// Nombre d'écritures réussies (chaque appel atomique compte pour une).
    private(set) var writeCount = 0
    private let clock: HistoryTestClock

    init(game: SavedGame) {
        stored = game
        clock = HistoryTestClock()
    }

    func replaceStored(_ game: SavedGame) {
        stored = game
    }

    private func write(_ game: SavedGame) throws(GameRepositoryError) {
        guard !failsWrites else {
            throw GameRepositoryError.storageFailure(.write, message: "Échec simulé.")
        }
        stored = game
        writeCount += 1
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
            try write(updated)
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
            if failsNextReplace {
                failsNextReplace = false
                throw GameRepositoryError.storageFailure(.write, message: "Échec simulé.")
            }
            try write(updated)
            return .saved(updated, removedRounds: removedRounds)
        }
    }

    func deleteLastRound(ofGame gameID: UUID) throws(GameRepositoryError) -> RoundDeletion {
        let deletion = try GameWritePlanner.planDeleteLast(of: try game(id: gameID), at: clock.next())
        try write(deletion.game)
        return deletion
    }

    func deleteRoundsAfterEarlyEnd(
        gameID: UUID,
        confirmedRoundIDs: [UUID]
    ) throws(GameRepositoryError) -> SavedGame {
        let plan = try GameWritePlanner.planDeleteRoundsAfterEarlyEnd(
            try game(id: gameID),
            confirmedRoundIDs: confirmedRoundIDs,
            at: clock.next()
        )
        try write(plan.game)
        return plan.game
    }

    func finishGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        guard let updated = try GameWritePlanner.planFinish(try game(id: id), at: clock.next()) else { return stored }
        try write(updated)
        return updated
    }

    func reopenGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        let current = try game(id: id)
        guard let updated = try GameWritePlanner.planReopen(current, otherActiveGameID: nil, at: clock.next()) else {
            return current
        }
        try write(updated)
        return updated
    }

    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        guard let updated = GameWritePlanner.planArchive(try game(id: id), at: clock.next()) else { return stored }
        try write(updated)
        return updated
    }

    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool { false }

    func deleteAllGames() throws(GameRepositoryError) {
        throw GameRepositoryError.storageFailure(.write, message: "Non pris en charge par la doublure.")
    }
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
        #expect(first.closerNote == "score doublé\u{00A0}: égalité avec Chloé")
        #expect(first.players.map(\.isClosing) == [true, false, false, false])
        #expect(first.players.map(\.isDoubled) == [true, false, false, false])

        let second = try row(model, index: 2)
        #expect(second.closerName == "Bob")
        #expect(second.isCloserDoubled)
        #expect(second.closerNote == "score doublé\u{00A0}: Alice a fait moins")
        #expect(second.players.map(\.isDoubled) == [false, true, false, false])

        let third = try row(model, index: 3)
        #expect(!third.isCloserDoubled)
        #expect(third.closerNote == "zéro n'est jamais doublé")
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
        #expect(first.hasPrefix("Manche 1, Alice a terminé, score doublé\u{00A0}: égalité avec Chloé."))
        #expect(first.contains("Alice 10 doublé à 20, total 20."))
        #expect(first.contains("Bob 24, total 24."))
        let fourth = try row(model, index: 4).accessibilityLabel
        #expect(fourth.contains("Dimitri moins 3, total 53."))
        #expect(fourth.contains("Alice 9, total 41."))
    }

    @Test("Liste de noms en français (formateur partagé)")
    func frenchList() {
        #expect(VerdictText.frenchList([]) == "")
        #expect(VerdictText.frenchList(["Alice"]) == "Alice")
        #expect(VerdictText.frenchList(["Alice", "Bob"]) == "Alice et Bob")
        #expect(VerdictText.frenchList(["Alice", "Bob", "Chloé"]) == "Alice, Bob et Chloé")
    }

    @Test("Textes des manches jouées après la fin : pluriels")
    func laterRoundsTexts() {
        #expect(LaterRoundsText.range([3]) == "la manche 3")
        #expect(LaterRoundsText.range([3, 4]) == "les manches 3 et 4")
        #expect(LaterRoundsText.range([3, 4, 5]) == "les manches 3 à 5")
        #expect(LaterRoundsText.playedAfterSentence([3]) == "La manche 3 a été jouée ensuite.")
        #expect(LaterRoundsText.playedAfterSentence([7, 8, 9]) == "Les manches 7 à 9 ont été jouées ensuite.")
        #expect(LaterRoundsText.deletionTitle([3]) == "Supprimer définitivement la manche 3\u{202F}?")
        #expect(LaterRoundsText.deletionTitle([7, 8, 9]) == "Supprimer définitivement 3 manches\u{202F}?")
        #expect(LaterRoundsText.deletionMessage([3]) == "La manche 3 sera effacée. Cette action ne peut pas être annulée.")
        #expect(LaterRoundsText.deletionButton([3, 4]) == "Supprimer 2 manches")
        #expect(LaterRoundsText.deletionButton([3]) == "Supprimer la manche 3")
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

    @Test("Modèle réutilisé seulement pour la même partie")
    func resolveKeepsModelOnlyForSameGame() throws {
        let repository = try seededRepository()
        let gameID = UITestSeed.withHistory.activeGameID
        let model = historyModel(repository, gameID)
        #expect(HistoryModel.resolve(model, gameID: gameID, repository: repository) === model)

        let otherID = Self.fixedID(0xC0)
        let other = HistoryModel.resolve(model, gameID: otherID, repository: repository)
        #expect(other !== model)
        #expect(other.gameID == otherID)
        #expect(HistoryModel.resolve(nil, gameID: gameID, repository: repository).gameID == gameID)
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
        #expect(model.actionError == nil)
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

    /// Partie `tieEnd` (Alice 105, Bob 26, Chloé 26) close comme terminée.
    private func finishedTieEnd() throws -> (InMemoryGameRepository, UUID) {
        let clock = HistoryTestClock()
        let repository = InMemoryGameRepository(now: { clock.next() })
        try UITestSeed.tieEnd.apply(to: repository)
        let gameID = UITestSeed.tieEnd.activeGameID
        _ = try repository.finishGame(id: gameID)
        return (repository, gameID)
    }

    @Test("Partie terminée : la correction est présentée directement, sans dialogue ni écriture")
    func finishedGamePresentsEditDirectly() throws {
        let (repository, gameID) = try finishedTieEnd()
        let before = try repository.game(id: gameID)
        let model = historyModel(repository, gameID)
        #expect(model.lifecycle == .finished)
        #expect(!model.canDeleteLastRound)
        #expect(model.lifecycleNote == "Partie terminée. Touchez une manche pour la corriger.")

        let roundID = Key.tieEnd.roundID(index: 1)
        #expect(model.requestEdit(roundID: roundID) == .present(roundID: roundID))
        #expect(model.actionError == nil)
        #expect(try repository.game(id: gameID) == before)
    }

    @Test("Partie terminée → correction annulée (bouton ou glissement) ⇒ toujours terminée, rien d'écrit")
    func finishedGameCancelledCorrectionKeepsFinished() throws {
        let (repository, gameID) = try finishedTieEnd()
        let before = try repository.game(id: gameID)
        let roundID = Key.tieEnd.roundID(index: 1)
        #expect(historyModel(repository, gameID).requestEdit(roundID: roundID) == .present(roundID: roundID))

        let entry = RoundEntryModel(gameID: gameID, mode: .edit(roundID: roundID), repository: repository)
        entry.setText("30", for: entry.fields[1].participantID)
        #expect(entry.canSave)
        // Glissement de la feuille : seul le filet de sécurité s'exécute, sans écriture.
        #expect(!entry.restoreLifecycleIfNeeded())
        // Bouton « Annuler » puis « Abandonner ».
        #expect(!entry.prepareForDismissal())
        #expect(!entry.needsLifecycleRestore)
        #expect(try repository.game(id: gameID) == before)
    }

    @Test("Partie terminée → correction qui garde la fin ⇒ toujours terminée, correction enregistrée")
    func finishedGameCorrectionKeepingEndStaysFinished() throws {
        let (repository, gameID) = try finishedTieEnd()
        let roundID = Key.tieEnd.roundID(index: 1)
        let entry = RoundEntryModel(gameID: gameID, mode: .edit(roundID: roundID), repository: repository)
        // Bob 24 → 25 : Alice reste à 105, la partie reste terminée.
        entry.setText("25", for: entry.fields[1].participantID)
        #expect(entry.save() == .saved)
        #expect(!entry.needsLifecycleRestore)

        let after = try repository.game(id: gameID)
        #expect(after.lifecycle == .finished)
        #expect(after.isOver)
        #expect(after.finishedAt != nil)
        #expect(after.rounds[0].entry(for: entry.fields[1].participantID)?.rawScore == 25)
        #expect(try repository.activeGame() == nil)

        let model = historyModel(repository, gameID)
        #expect(model.lifecycle == .finished)
        #expect(try row(model, index: 1).isCorrected)
    }

    @Test("Correction qui annule la fin ⇒ partie active, après confirmation « La partie reprend »")
    func finishedGameCorrectionCancellingEndResumes() throws {
        let (repository, gameID) = try finishedTieEnd()
        let before = try repository.game(id: gameID)
        let roundID = Key.tieEnd.roundID(index: 3)
        let entry = RoundEntryModel(gameID: gameID, mode: .edit(roundID: roundID), repository: repository)
        // Alice 45 → 5 : 65 points, plus personne n'atteint 100.
        entry.setText("5", for: entry.fields[0].participantID)

        #expect(entry.save() == .needsDecision)
        let decision = try #require(entry.pendingDecision)
        #expect(decision == .gameResumes(targetScore: 100))
        #expect(decision.title == "La partie reprend")
        #expect(decision.cancelTitle == "Revenir à la saisie")
        // Rien n'est écrit avant la confirmation.
        #expect(try repository.game(id: gameID) == before)

        #expect(entry.confirm(decision) == .saved)
        let after = try repository.game(id: gameID)
        #expect(after.lifecycle == .active)
        #expect(!after.isOver)
        #expect(after.finishedAt == nil)
        #expect(!entry.needsLifecycleRestore)
        #expect(try repository.activeGame()?.id == gameID)
    }

    @Test("Partie terminée, échec de la correction après réouverture ⇒ statut « terminée » rétabli aussitôt")
    func finishedGameFailedCorrectionRestoresFinished() throws {
        let alice = Participant(id: Self.fixedID(1), displayName: "Alice", displayOrder: 0)
        let bob = Participant(id: Self.fixedID(2), displayName: "Bob", displayOrder: 1)
        let ids = [alice.id, bob.id]
        let date = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let finished = try SavedGame(
            id: Self.fixedID(0xC0),
            title: nil,
            lifecycle: .finished,
            rules: .classic,
            participants: [alice, bob],
            rounds: [
                RoundInput(id: Self.fixedID(21), index: 1, closingParticipantID: bob.id, entries: Self.points(ids, [60, 4])),
                RoundInput(id: Self.fixedID(22), index: 2, closingParticipantID: bob.id, entries: Self.points(ids, [45, 8])),
            ],
            roundInfo: [:],
            createdAt: date,
            updatedAt: date,
            finishedAt: date,
            archivedAt: nil
        )
        let repository = SingleGameRepository(game: finished)
        let entry = RoundEntryModel(gameID: finished.id, mode: .edit(roundID: Self.fixedID(21)), repository: repository)
        entry.setText("5", for: bob.id)

        repository.failsNextReplace = true
        #expect(entry.save() == .failed)
        #expect(entry.saveErrorMessage != nil)
        #expect(!entry.needsLifecycleRestore)
        #expect(repository.stored.lifecycle == .finished)
        #expect(repository.stored.rounds == finished.rounds)

        // Nouvelle tentative : réouverture, correction, puis « terminée » rétabli.
        entry.dismissSaveError()
        #expect(entry.save() == .saved)
        #expect(repository.stored.lifecycle == .finished)
        #expect(repository.stored.rounds[0].entry(for: bob.id)?.rawScore == 5)
    }

    @Test("Partie terminée alors qu'une autre partie est en cours : message, aucune feuille, rien d'écrit")
    func finishedGameEditRefusedWhenAnotherGameIsActive() throws {
        let repository = try seededRepository()
        let gameID = Key.historyFinished.id
        let before = try repository.game(id: gameID)
        let model = historyModel(repository, gameID)
        let roundID = Key.historyFinished.roundID(index: 1)
        #expect(model.requestEdit(roundID: roundID) == .unavailable)
        let message = try #require(model.actionError)
        #expect(message.contains("Une autre partie est en cours"))
        #expect(try repository.game(id: gameID) == before)
        #expect(try repository.activeGame()?.id == Key.historyActive.id)

        // Défense en profondeur : la feuille de saisie bloque aussi l'enregistrement.
        let entry = RoundEntryModel(gameID: gameID, mode: .edit(roundID: roundID), repository: repository)
        #expect(!entry.canSave)
        #expect(entry.blockingReasons == [CorrectionText.anotherGameActive])
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
        #expect(notice.confirmationTitle == "Supprimer définitivement 2 manches\u{202F}?")
        #expect(notice.confirmationMessage
            == "Les manches 3 et 4 seront effacées. Cette action ne peut pas être annulée.")
        #expect(notice.confirmationButtonTitle == "Supprimer 2 manches")
        #expect(notice.message.contains("manche 2"))
        #expect(notice.message.contains("Les manches 3 et 4 ont été jouées ensuite."))
        #expect(model.canResolveInconsistency)
        // La suppression unitaire (annulable) est remplacée par la résolution explicite.
        #expect(!model.canDeleteLastRound)
        #expect(try row(model, index: 2).isEndingRound)
        #expect(try row(model, index: 3).isAfterGameEnd)
        #expect(try row(model, index: 4).isAfterGameEnd)
        let firstRow = try row(model, index: 1)
        #expect(!firstRow.isAfterGameEnd)
        #expect(repository.stored.rounds.count == 4)
        #expect(repository.writeCount == 0)
    }

    @Test("Résolution confirmée : seules les manches postérieures sont supprimées")
    func resolveDeletesOnlySubsequentRounds() throws {
        let original = try Self.inconsistentGame()
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)

        #expect(model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        // Une seule écriture atomique (plus de suppressions une à une).
        #expect(repository.writeCount == 1)
        #expect(repository.stored.rounds == Array(original.rounds.prefix(2)))
        #expect(repository.stored.computation.inconsistency == nil)
        #expect(model.inconsistency == nil)
        #expect(model.actionError == nil)
        #expect(model.rows.map(\.index) == [2, 1])
        #expect(model.undoableDeletion == nil)
    }

    @Test("Résolution sur une partie close : suppression atomique, la partie reste terminée")
    func resolveOnFinishedGameKeepsFinished() throws {
        let original = try Self.inconsistentGame(lifecycle: .finished)
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)
        #expect(model.canResolveInconsistency)
        #expect(!notice.confirmationMessage.contains("rouverte"))

        #expect(model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(repository.writeCount == 1)
        #expect(repository.stored.lifecycle == .finished)
        #expect(repository.stored.finishedAt == original.finishedAt)
        #expect(repository.stored.rounds == Array(original.rounds.prefix(2)))
        #expect(model.lifecycle == .finished)
        #expect(model.inconsistency == nil)
    }

    @Test("Échec de sauvegarde pendant la résolution : rien n'est supprimé, erreur affichée")
    func resolutionFailureDeletesNothing() throws {
        let original = try Self.inconsistentGame()
        let repository = SingleGameRepository(game: original)
        let model = historyModel(repository, original.id)
        let notice = try #require(model.inconsistency)

        repository.failsWrites = true
        #expect(!model.deleteRoundsAfterEarlyEnd(confirmed: notice))
        #expect(model.actionError != nil)
        #expect(repository.writeCount == 0)
        #expect(repository.stored == original)
        // L'incohérence reste signalée à l'identique ; une nouvelle tentative est possible.
        #expect(model.inconsistency?.subsequentRoundIndices == [3, 4])
        repository.failsWrites = false
        let retry = try #require(model.inconsistency)
        #expect(model.deleteRoundsAfterEarlyEnd(confirmed: retry))
        #expect(repository.stored.rounds == Array(original.rounds.prefix(2)))
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
        #expect(repository.writeCount == 0)
        #expect(repository.stored.rounds.count == 3)
        #expect(model.actionError == GameRepositoryError.staleEarlyEndDecision(gameID: original.id).userFacingMessage)
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
        #expect(repository.writeCount == 0)
        #expect(repository.stored.rounds.count == 4)
    }

    // MARK: Saisie par cartes (Lot 3)

    /// Grille d'Alice du jeu `withCards` : 7/7/7, 1/2/3, colonne retirée, −2/−2/−2 ⇒ 6.
    private static func withCardsAliceGrid() throws -> CardGrid {
        try CardGrid(rows: [[7, 1, nil, -2], [7, 2, nil, -2], [7, 3, nil, -2]], removedColumns: [2])
    }

    private func cardsModel() throws -> HistoryModel {
        let clock = HistoryTestClock()
        let repository = InMemoryGameRepository(now: { clock.next() })
        try UITestSeed.withCards.apply(to: repository)
        return historyModel(repository, Key.cards.id)
    }

    @Test("Manche saisie en cartes : grille d'origine exposée, mention « cartes », scores du moteur")
    func cardEntryIsShown() throws {
        let model = try cardsModel()
        let first = try row(model, index: 1)
        let expectedGrid = try Self.withCardsAliceGrid()
        #expect(first.players.map(\.isCardsEntry) == [true, false, false])
        #expect(first.players[0].cardGrid == expectedGrid)
        #expect(first.players.map(\.rawScore) == [6, 10, 4])
        #expect(first.players.map(\.effectiveScore) == [6, 20, 4])
        #expect(first.hasCardEntries)
        #expect(first.cardPlayers.map(\.name) == ["Alice"])
        #expect(first.cardsButtonTitle == "Voir les cartes de la manche 1")
    }

    @Test("Manche saisie en points : aucune grille, aucun bouton de consultation")
    func pointsEntryHasNoGrid() throws {
        let model = historyModel(try seededRepository(), Key.historyActive.id)
        #expect(model.rows.allSatisfy { !$0.hasCardEntries })
        #expect(model.rows.flatMap(\.players).allSatisfy { $0.cardGrid == nil })
    }

    @Test("VoiceOver : saisie en cartes annoncée dans la phrase de la manche")
    func cardEntryIsSpoken() throws {
        let label = try row(try cardsModel(), index: 1).accessibilityLabel
        #expect(label.contains("Alice 6, saisi en cartes, total 6."))
        #expect(label.contains("Bob 10 doublé à 20, total 20."))
        #expect(label.contains("Chloé 4, total 4."))
    }

    @Test("Consultation d'une grille : textes de la présentation partagée avec l'éditeur (valeurs du Kit)")
    func readOnlyGridUsesSharedPresentation() throws {
        let model = try cardsModel()
        let alice = try #require(try row(model, index: 1).cardPlayers.first)
        let grid = try #require(alice.cardGrid)
        let presentation = CardGridPresentation(grid: grid, playerName: alice.name, position: alice.position)
        #expect(presentation.rawScore == 6)
        #expect(presentation.totalAccessibilityLabel == "Alice, total brut 6 points")
        #expect(presentation.columns.map(\.shortStatus) == ["Non comptée", nil, "Retirée", "Non comptée"])
        #expect(presentation.columns.map(\.subtotalText) == ["0", "6", "0", "0"])
    }
}
#endif
