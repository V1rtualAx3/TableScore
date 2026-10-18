import Foundation
import SwiftData
import TableScoreKit

/// Dépôt SwiftData local (aucune synchronisation, voir `PersistenceController`).
///
/// Transactions : chaque opération d'écriture
/// 1. relit la partie et la valide entièrement par le moteur (`RecordMapper`) ;
/// 2. obtient un plan pur (`GameWritePlanner`) ;
/// 3. applique le plan dans un contexte privé sans sauvegarde automatique ;
/// 4. sauvegarde une seule fois ; en cas d'échec, le contexte est **abandonné** et remplacé par un
///    contexte neuf, puis une erreur typée est levée.
/// Aucun succès n'est renvoyé sans sauvegarde réussie.
///
/// Pourquoi abandonner le contexte plutôt que `rollback()` : après un échec réel de `save()`
/// (permission, disque plein, E/S), SwiftData peut laisser dans le contexte des instances dont les
/// données n'existent plus dans le store (ex. manche insérée encore référencée par la relation
/// `rounds` de la partie en cache) ; y accéder provoque un `fatalError` de SwiftData. Un contexte
/// neuf ne contient aucune instance : la relecture suivante repart du store, inchangé puisque la
/// transaction SQLite a échoué. Règle : après un échec, plus aucun objet issu de l'ancien contexte
/// n'est touché (les méthodes ne conservent aucun enregistrement entre deux appels).
///
/// Écrivain unique : une seule instance par conteneur dans l'application (le contexte conserve
/// ses objets en cache ; un second écrivain concurrent pourrait lire des valeurs périmées).
///
/// Effacement physique (`deleteAllGames` sur un store fichier) : le dépôt **reste la même
/// instance** (celle détenue par `AppDependencies` et les view models) ; il remplace en interne
/// son conteneur par un store vide recréé. Pendant l'opération, et si la recréation échoue, le
/// store est marqué indisponible : toute lecture ou écriture lève une erreur, jamais de résultat
/// vide présenté comme réel.
@MainActor
final class SwiftDataGameRepository: GameRepository {
    /// Point d'injection de la sauvegarde (tests d'échec et de rollback uniquement).
    typealias SaveHandler = @MainActor (ModelContext) throws -> Void

    /// Fichiers d'un store sur disque, nécessaires à l'effacement physique.
    struct FileStore {
        let location: StoreLocation
        let fileSystem: any StoreFileSystem
    }

    /// Conservé explicitement : le contexte ne doit jamais survivre à son conteneur. Remplacé
    /// uniquement par l'effacement physique.
    private var container: ModelContainer
    /// Remplacé après tout échec d'écriture (voir ci-dessus) ; jamais conservé ailleurs.
    private var context: ModelContext
    private let now: @MainActor () -> Date
    private let saveHandler: SaveHandler
    /// `nil` : store en mémoire (la suppression logique suffit, rien n'est écrit sur disque).
    private let fileStore: FileStore?
    /// Faux pendant l'effacement physique et si le store vide n'a pas pu être recréé.
    private(set) var isStoreAvailable = true

    init(
        container: ModelContainer,
        fileStore: FileStore? = nil,
        now: @escaping @MainActor () -> Date = { Date() },
        saveHandler: @escaping SaveHandler = { try $0.save() }
    ) {
        self.container = container
        self.context = Self.makeContext(container)
        self.fileStore = fileStore
        self.now = now
        self.saveHandler = saveHandler
    }

    // MARK: Lecture

    func activeGame() throws(GameRepositoryError) -> SavedGame? {
        let records = try fetchActiveRecords()
        guard records.count <= 1 else {
            throw GameRepositoryError.corruptedData(gameID: nil, .multipleActiveGames(count: records.count))
        }
        guard let record = records.first else { return nil }
        return try map(record)
    }

    func game(id: UUID) throws(GameRepositoryError) -> SavedGame {
        try map(try requireRecord(id: id))
    }

    func closedGames() throws(GameRepositoryError) -> [GameListing] {
        let activeRaw = GameLifecycle.active.rawValue
        let descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate<GameRecord> { $0.lifecycleRaw != activeRaw }
        )
        var listings: [GameListing] = []
        for record in try fetch(descriptor) {
            do {
                listings.append(.readable(try RecordMapper.savedGame(from: record)))
            } catch {
                listings.append(.corrupted(
                    id: record.gameID,
                    updatedAt: record.updatedAt,
                    reason: PersistedDataCorruption.from(error)
                ))
            }
        }
        return GameWritePlanner.sortedListings(listings)
    }

    // MARK: Écriture

    func createGame(
        id: UUID,
        participants: [Participant],
        rules: GameRules,
        title: String?
    ) throws(GameRepositoryError) -> SavedGame {
        discardPendingChanges()
        let date = now()
        let candidate = try GameWritePlanner.newGame(
            id: id,
            title: title,
            participants: participants,
            rules: rules,
            at: date
        )
        if let existing = try fetchRecords(id: id).first {
            return try GameWritePlanner.resolveExistingCreation(try map(existing), candidate: candidate)
        }
        let previousActive = try fetchActiveRecords()

        do {
            for record in previousActive {
                supersede(record, at: date)
            }
            try insert(candidate)
        } catch {
            discardContext()
            throw GameRepositoryError.from(error, operation: .write)
        }
        try commit()
        return candidate
    }

    func appendRound(_ round: RoundInput, toGame gameID: UUID) throws(GameRepositoryError) -> AppendRoundOutcome {
        discardPendingChanges()
        let record = try requireRecord(id: gameID)
        let current = try map(record)
        let plan = try GameWritePlanner.planAppend(
            round,
            to: current,
            roundIDUsedElsewhere: try isRoundID(round.id, usedOutsideGame: gameID),
            at: now()
        )
        switch plan {
        case .alreadySaved:
            return .alreadySaved(current)
        case .insert(let updated):
            do {
                try insertRound(
                    updated.normalized(round),
                    into: record,
                    info: updated.info(forRound: round.id),
                    at: updated.updatedAt
                )
                RecordMapper.apply(updated, toHeaderOf: record)
            } catch {
                discardContext()
                throw GameRepositoryError.from(error, operation: .write)
            }
            try commit()
            return .inserted(updated)
        }
    }

    func replaceRound(
        _ round: RoundInput,
        inGame gameID: UUID,
        resolution: EarlyEndResolution
    ) throws(GameRepositoryError) -> RoundReplacementOutcome {
        discardPendingChanges()
        let record = try requireRecord(id: gameID)
        let current = try map(record)
        let plan = try GameWritePlanner.planReplace(round, in: current, resolution: resolution, at: now())
        switch plan {
        case .unchanged:
            return .unchanged(current)
        case .requiresDecision(let conflict):
            // Rien n'a été modifié dans le contexte : la décision revient à l'interface.
            return .requiresDecision(conflict)
        case .write(let updated, let replacedRound, let removedRounds):
            do {
                if let replacedRound {
                    let modifiedAt = updated.info(forRound: replacedRound.id)?.modifiedAt ?? updated.updatedAt
                    try updateRound(replacedRound, in: record, modifiedAt: modifiedAt)
                }
                let removedIDs = Set(removedRounds.map(\.id))
                for roundRecord in record.rounds where removedIDs.contains(roundRecord.roundID) {
                    context.delete(roundRecord)
                }
                RecordMapper.apply(updated, toHeaderOf: record)
            } catch {
                discardContext()
                throw GameRepositoryError.from(error, operation: .write)
            }
            try commit()
            return .saved(updated, removedRounds: removedRounds)
        }
    }

    func deleteLastRound(ofGame gameID: UUID) throws(GameRepositoryError) -> RoundDeletion {
        discardPendingChanges()
        let record = try requireRecord(id: gameID)
        let deletion = try GameWritePlanner.planDeleteLast(of: try map(record), at: now())
        let doomed = record.rounds.filter { $0.roundID == deletion.deletedRound.id }
        guard !doomed.isEmpty else {
            throw GameRepositoryError.corruptedData(
                gameID: gameID,
                .missingRoundRecord(roundID: deletion.deletedRound.id)
            )
        }
        for roundRecord in doomed {
            context.delete(roundRecord)
        }
        RecordMapper.apply(deletion.game, toHeaderOf: record)
        try commit()
        return deletion
    }

    func deleteRoundsAfterEarlyEnd(
        gameID: UUID,
        confirmedRoundIDs: [UUID]
    ) throws(GameRepositoryError) -> SavedGame {
        discardPendingChanges()
        let record = try requireRecord(id: gameID)
        let plan = try GameWritePlanner.planDeleteRoundsAfterEarlyEnd(
            try map(record),
            confirmedRoundIDs: confirmedRoundIDs,
            at: now()
        )
        let removedIDs = Set(plan.removedRounds.map(\.id))
        let doomed = record.rounds.filter { removedIDs.contains($0.roundID) }
        // Chaque manche supprimée doit correspondre à exactement un enregistrement.
        guard doomed.count == removedIDs.count, Set(doomed.map(\.roundID)) == removedIDs else {
            let missing = removedIDs.subtracting(doomed.map(\.roundID)).first ?? gameID
            throw GameRepositoryError.corruptedData(gameID: gameID, .missingRoundRecord(roundID: missing))
        }
        for roundRecord in doomed {
            context.delete(roundRecord)
        }
        RecordMapper.apply(plan.game, toHeaderOf: record)
        // Une seule sauvegarde : toutes les manches ou aucune (contexte abandonné en cas d'échec).
        try commit()
        return plan.game
    }

    func finishGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        discardPendingChanges()
        let record = try requireRecord(id: id)
        let current = try map(record)
        guard let updated = try GameWritePlanner.planFinish(current, at: now()) else { return current }
        RecordMapper.apply(updated, toHeaderOf: record)
        try commit()
        return updated
    }

    func reopenGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        discardPendingChanges()
        let record = try requireRecord(id: id)
        let current = try map(record)
        let otherActive = try fetchActiveRecords().first { $0.gameID != id }
        guard let updated = try GameWritePlanner.planReopen(
            current,
            otherActiveGameID: otherActive?.gameID,
            at: now()
        ) else { return current }
        RecordMapper.apply(updated, toHeaderOf: record)
        try commit()
        return updated
    }

    func archiveGame(id: UUID) throws(GameRepositoryError) -> SavedGame {
        discardPendingChanges()
        let record = try requireRecord(id: id)
        let current = try map(record)
        guard let updated = GameWritePlanner.planArchive(current, at: now()) else { return current }
        RecordMapper.apply(updated, toHeaderOf: record)
        try commit()
        return updated
    }

    @discardableResult
    func deleteGame(id: UUID) throws(GameRepositoryError) -> Bool {
        discardPendingChanges()
        // Fonctionne aussi sur une partie illisible ou dupliquée : aucun décodage nécessaire.
        let records = try fetchRecords(id: id)
        guard !records.isEmpty else { return false }
        for record in records {
            // Suppression explicite des enfants, sans dépendre uniquement de la cascade.
            for roundRecord in record.rounds { context.delete(roundRecord) }
            for participantRecord in record.participants { context.delete(participantRecord) }
            context.delete(record)
        }
        try commit()
        return true
    }

    func deleteAllGames() throws(GameRepositoryError) {
        // Store indisponible après un effacement interrompu : les parties sont déjà supprimées,
        // seul l'effacement physique et la recréation sont repris.
        if isStoreAvailable {
            try deleteAllRecords()
        }
        guard let fileStore else { return }
        try eraseAndRecreateStore(fileStore)
    }

    /// Suppression logique en une seule transaction (tout ou rien).
    private func deleteAllRecords() throws(GameRepositoryError) {
        discardPendingChanges()
        // Aucun décodage : fonctionne aussi sur des parties illisibles ou dupliquées.
        let records = try fetch(FetchDescriptor<GameRecord>())
        // Enfants orphelins éventuels inclus : « tout supprimer » ne laisse aucune donnée.
        let rounds = try fetch(FetchDescriptor<RoundRecord>())
        let participants = try fetch(FetchDescriptor<ParticipantRecord>())
        guard !records.isEmpty || !rounds.isEmpty || !participants.isEmpty else { return }
        for roundRecord in rounds { context.delete(roundRecord) }
        for participantRecord in participants { context.delete(participantRecord) }
        for record in records { context.delete(record) }
        // Une seule sauvegarde : tout ou rien (contexte abandonné en cas d'échec).
        try commit()
    }

    /// Effacement physique après la suppression logique : SQLite ne remet pas à zéro les pages
    /// libérées (et `PRAGMA secure_delete` n'est pas accessible via SwiftData) ; les prénoms
    /// pourraient donc subsister dans la base ou le `-wal`. Étapes :
    /// 1. fermeture du store : le conteneur fichier est remplacé par un conteneur vide en mémoire
    ///    (plus aucune référence du dépôt vers l'ancien), store marqué indisponible ;
    /// 2. `StoreFiles.eraseClosedStore` : dossier renommé atomiquement puis supprimé ;
    /// 3. store vide recréé dans un dossier neuf et protégé, puis installé.
    /// Si le renommage échoue, l'ancien store (déjà vidé) est rouvert : `.eraseFiles`.
    /// Si la recréation échoue : store indisponible, `.reopenAfterErase`.
    private func eraseAndRecreateStore(_ fileStore: FileStore) throws(GameRepositoryError) {
        let placeholder: ModelContainer
        do {
            placeholder = try PersistenceController.makeContainer(storage: .inMemory)
        } catch {
            // Store non fermé : rien n'est effacé, l'ancien conteneur reste en place.
            throw GameRepositoryError.storageFailure(.eraseFiles, message: ErrorDiagnostics.summary(of: error))
        }
        isStoreAvailable = false
        install(placeholder)

        var eraseError: GameRepositoryError?
        do {
            let complete = try StoreFiles.eraseClosedStore(fileStore.location, fileSystem: fileStore.fileSystem)
            if !complete {
                // Restes supprimés au prochain lancement (`StoreFiles.prepare`).
                eraseError = .storageFailure(.eraseFiles, message: "ErasureLeftovers")
            }
        } catch {
            // Dossier non renommé : rien n'est effacé, l'ancien store (déjà vidé) est rouvert.
            eraseError = GameRepositoryError.from(error, operation: .eraseFiles)
        }

        let reopened: ModelContainer
        do {
            reopened = try PersistenceController.makeEmptyFileContainer(
                at: fileStore.location,
                fileSystem: fileStore.fileSystem
            )
        } catch {
            throw GameRepositoryError.storageFailure(.reopenAfterErase, message: ErrorDiagnostics.summary(of: error))
        }
        install(reopened)
        isStoreAvailable = true
        if let eraseError { throw eraseError }
    }

    /// Remplace conteneur et contexte ; l'ancien contexte n'est plus touché.
    private func install(_ newContainer: ModelContainer) {
        container = newContainer
        context = Self.makeContext(newContainer)
    }

    // MARK: Application des plans

    private func insert(_ game: SavedGame) throws(GameRepositoryError) {
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
            try insertRound(round, into: record, info: game.info(forRound: round.id), at: game.updatedAt)
        }
    }

    private func insertRound(
        _ round: RoundInput,
        into record: GameRecord,
        info: SavedRoundInfo?,
        at date: Date
    ) throws(GameRepositoryError) {
        let roundRecord = RoundRecord(
            roundID: round.id,
            roundIndex: round.index,
            closingParticipantID: round.closingParticipantID,
            entriesPayload: try RecordMapper.entriesPayload(of: round),
            createdAt: info?.createdAt ?? date,
            modifiedAt: info?.modifiedAt ?? date
        )
        context.insert(roundRecord)
        roundRecord.game = record
    }

    private func updateRound(_ round: RoundInput, in record: GameRecord, modifiedAt: Date) throws(GameRepositoryError) {
        let payload = try RecordMapper.entriesPayload(of: round)
        let matching = record.rounds.filter { $0.roundID == round.id }
        guard matching.count == 1, let roundRecord = matching.first else {
            throw GameRepositoryError.corruptedData(gameID: record.gameID, .missingRoundRecord(roundID: round.id))
        }
        roundRecord.closingParticipantID = round.closingParticipantID
        roundRecord.entriesPayload = payload
        roundRecord.modifiedAt = modifiedAt
    }

    /// Ancienne partie active lors d'une création ; une partie illisible est rangée telle quelle.
    private func supersede(_ record: GameRecord, at date: Date) {
        if let game = try? RecordMapper.savedGame(from: record) {
            RecordMapper.apply(GameWritePlanner.superseded(game, at: date), toHeaderOf: record)
        } else {
            record.lifecycleRaw = GameLifecycle.archived.rawValue
            record.archivedAt = date
            record.updatedAt = date
        }
    }

    // MARK: Accès au stockage

    private func map(_ record: GameRecord) throws(GameRepositoryError) -> SavedGame {
        do {
            return try RecordMapper.savedGame(from: record)
        } catch {
            throw GameRepositoryError.corruptedData(gameID: record.gameID, PersistedDataCorruption.from(error))
        }
    }

    private func requireRecord(id: UUID) throws(GameRepositoryError) -> GameRecord {
        let records = try fetchRecords(id: id)
        guard records.count <= 1 else {
            throw GameRepositoryError.corruptedData(gameID: id, .duplicateGameID(id))
        }
        guard let record = records.first else { throw GameRepositoryError.gameNotFound(id) }
        return record
    }

    private func fetchRecords(id: UUID) throws(GameRepositoryError) -> [GameRecord] {
        let targetID = id
        let descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate<GameRecord> { $0.gameID == targetID }
        )
        return try fetch(descriptor)
    }

    private func fetchActiveRecords() throws(GameRepositoryError) -> [GameRecord] {
        let activeRaw = GameLifecycle.active.rawValue
        let descriptor = FetchDescriptor<GameRecord>(
            predicate: #Predicate<GameRecord> { $0.lifecycleRaw == activeRaw }
        )
        return try fetch(descriptor)
    }

    private func isRoundID(_ roundID: UUID, usedOutsideGame gameID: UUID) throws(GameRepositoryError) -> Bool {
        let targetID = roundID
        let descriptor = FetchDescriptor<RoundRecord>(
            predicate: #Predicate<RoundRecord> { $0.roundID == targetID }
        )
        let records = try fetch(descriptor)
        return records.contains { $0.game?.gameID != gameID }
    }

    private func fetch<Record: PersistentModel>(_ descriptor: FetchDescriptor<Record>) throws(GameRepositoryError) -> [Record] {
        guard isStoreAvailable else {
            throw GameRepositoryError.storageFailure(.read, message: "StoreUnavailable")
        }
        do {
            return try context.fetch(descriptor)
        } catch {
            throw GameRepositoryError.storageFailure(.read, message: ErrorDiagnostics.summary(of: error))
        }
    }

    /// Sauvegarde unique de la transaction ; en cas d'échec, le contexte fautif est abandonné
    /// (aucun `rollback()` ni accès à ses objets) et remplacé par un contexte neuf.
    private func commit() throws(GameRepositoryError) {
        guard isStoreAvailable else {
            discardContext()
            throw GameRepositoryError.storageFailure(.write, message: "StoreUnavailable")
        }
        do {
            try saveHandler(context)
        } catch {
            discardContext()
            throw GameRepositoryError.storageFailure(.write, message: ErrorDiagnostics.summary(of: error))
        }
    }

    /// Filet de sécurité : aucune modification résiduelle ne doit être emportée par une écriture.
    private func discardPendingChanges() {
        if context.hasChanges {
            discardContext()
        }
    }

    /// Remplace le contexte courant par un contexte neuf, sans toucher à l'ancien ni à ses objets.
    private func discardContext() {
        context = Self.makeContext(container)
    }

    private static func makeContext(_ container: ModelContainer) -> ModelContext {
        let context = ModelContext(container)
        // Sauvegarde explicite uniquement : aucune écriture partielle à un instant arbitraire.
        context.autosaveEnabled = false
        return context
    }
}
