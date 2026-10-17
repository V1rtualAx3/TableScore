import Foundation
import SwiftData
import Testing
import TableScoreKit
@testable import TableScore

/// Sauvegarde injectable : simule un échec d'écriture pour vérifier le rollback.
@MainActor
final class SaveFailureSwitch {
    struct SimulatedFailure: Error {}

    var failNextSave = false

    func save(_ context: ModelContext) throws {
        if failNextSave {
            failNextSave = false
            throw SimulatedFailure()
        }
        try context.save()
    }
}

@Suite("Persistance SwiftData : relance, rollback, corruption, configuration")
@MainActor
struct PersistenceSwiftDataTests {
    private typealias Fx = PersistenceFixtures

    // MARK: Reprise

    @Test("Relance : un nouveau contexte sur le même conteneur relit exactement la partie")
    func resumeWithNewContext() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let clock = TestClock()
        let first = SwiftDataGameRepository(container: container, now: { clock.next() })
        let rules = GameRules(targetScore: 150, houseRules: HouseRules(isCloserPenaltyDisabled: true))
        _ = try first.createGame(id: Fx.gameA, participants: Fx.players(3), rules: rules, title: "Revanche")

        let cardEntry = try RoundEntry.cards(Fx.chloe, grid: try Fx.cardGrid())
        let r1 = RoundInput(
            id: UUID(),
            index: 1,
            closingParticipantID: Fx.alice,
            entries: [.points(Fx.alice, rawScore: 10), .points(Fx.bob, rawScore: 5), cardEntry]
        )
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: -2, Fx.bob: 0, Fx.chloe: 12])
        _ = try first.appendRound(r1, toGame: Fx.gameA)
        _ = try first.appendRound(r2, toGame: Fx.gameA)
        _ = try first.replaceRound(
            Fx.round(2, closer: Fx.bob, [Fx.alice: -2, Fx.bob: 1, Fx.chloe: 12], id: r2.id),
            inGame: Fx.gameA
        )
        let lastKnown = try first.game(id: Fx.gameA)
        // Règle maison : le clôturant n'est pas doublé malgré un score supérieur.
        #expect(lastKnown.computation.rounds[0].scoring.closingEffectiveScore == 10)

        let relaunched = SwiftDataGameRepository(container: container)
        #expect(try relaunched.activeGame() == lastKnown)
        #expect(try relaunched.activeGame()?.rules == rules)
    }

    @Test("Relance réelle : nouveau conteneur sur le même fichier")
    func resumeFromDisk() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TableScoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: PersistenceController.storeFileName, directoryHint: .notDirectory)
        let clock = TestClock()

        let saved: SavedGame
        do {
            let container = try PersistenceController.makeContainer(storage: .file(storeURL))
            let repo = SwiftDataGameRepository(container: container, now: { clock.next() })
            _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
            saved = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 8]), toGame: Fx.gameA).game
        }
        #expect(FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))

        let reopened = try PersistenceController.makeContainer(storage: .file(storeURL))
        #expect(try SwiftDataGameRepository(container: reopened).activeGame() == saved)
    }

    @Test("Deux conteneurs en mémoire sont isolés")
    func inMemoryContainersAreIsolated() throws {
        let first = SwiftDataGameRepository(container: try PersistenceController.makeContainer(storage: .inMemory))
        _ = try first.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let second = SwiftDataGameRepository(container: try PersistenceController.makeContainer(storage: .inMemory))
        #expect(try second.activeGame() == nil)
    }

    // MARK: Atomicité

    @Test("Échec de sauvegarde d'une manche : rollback, erreur remontée, nouvelle tentative possible")
    func failedAppendRollsBack() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let clock = TestClock()
        let failures = SaveFailureSwitch()
        let repo = SwiftDataGameRepository(
            container: container,
            now: { clock.next() },
            saveHandler: { try failures.save($0) }
        )
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let before = try repo.game(id: Fx.gameA)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 4, Fx.bob: 6])

        failures.failNextSave = true
        let error = repositoryError { _ = try repo.appendRound(round, toGame: Fx.gameA) }
        #expect(error?.isWriteFailure == true)
        #expect(try repo.game(id: Fx.gameA) == before)
        #expect(try SwiftDataGameRepository(container: container).game(id: Fx.gameA) == before)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<RoundRecord>()) == 0)

        // Même brouillon (même identifiant) : la nouvelle tentative enregistre une seule manche.
        guard case .inserted = try repo.appendRound(round, toGame: Fx.gameA) else {
            Issue.record("La nouvelle tentative doit enregistrer la manche.")
            return
        }
        #expect(try SwiftDataGameRepository(container: container).game(id: Fx.gameA).rounds.count == 1)
    }

    @Test("Échec de sauvegarde d'une création : l'ancienne partie reste active")
    func failedCreateKeepsPreviousActiveGame() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let clock = TestClock()
        let failures = SaveFailureSwitch()
        let repo = SwiftDataGameRepository(
            container: container,
            now: { clock.next() },
            saveHandler: { try failures.save($0) }
        )
        let gameA = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)

        failures.failNextSave = true
        let error = repositoryError { _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(3), rules: .classic) }
        #expect(error?.isWriteFailure == true)
        #expect(try repo.activeGame() == gameA)
        let notFound = repositoryError { _ = try repo.game(id: Fx.gameB) }
        #expect(notFound == GameRepositoryError.gameNotFound(Fx.gameB))
        #expect(try SwiftDataGameRepository(container: container).activeGame() == gameA)
    }

    @Test("Suppressions : aucun enregistrement orphelin")
    func deletionsLeaveNoOrphans() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let repo = SwiftDataGameRepository(container: container)
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(3), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2, Fx.chloe: 3]), toGame: Fx.gameA)
        _ = try repo.appendRound(Fx.round(2, closer: Fx.bob, [Fx.alice: 1, Fx.bob: 2, Fx.chloe: 3]), toGame: Fx.gameA)

        _ = try repo.deleteLastRound(ofGame: Fx.gameA)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<RoundRecord>()) == 1)

        #expect(try repo.deleteGame(id: Fx.gameA))
        let context = ModelContext(container)
        #expect(try context.fetchCount(FetchDescriptor<GameRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ParticipantRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RoundRecord>()) == 0)
    }

    @Test("Échec de sauvegarde : correction avec suppression, suppression de manche, fin, réouverture et archivage annulés")
    func failedHistoryAndLifecycleWritesRollBack() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let clock = TestClock()
        let failures = SaveFailureSwitch()
        let repo = SwiftDataGameRepository(
            container: container,
            now: { clock.next() },
            saveHandler: { try failures.save($0) }
        )
        _ = try repo.createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        let r2 = Fx.round(2, closer: Fx.bob, [Fx.alice: 40, Fx.bob: 0])
        let r3 = Fx.round(3, closer: Fx.bob, [Fx.alice: 5, Fx.bob: 0])
        for round in [Fx.round(1, closer: Fx.bob, [Fx.alice: 50, Fx.bob: 0]), r2, r3] {
            _ = try repo.appendRound(round, toGame: Fx.gameA)
        }
        let corrected = Fx.round(2, closer: Fx.bob, [Fx.alice: 60, Fx.bob: 0], id: r2.id)
        let truncate = EarlyEndResolution.deleteRoundsAfterEarlyEnd(confirmedRoundIDs: [r3.id])

        try expectFailedSaveRollsBack(repo, failures: failures, container: container) {
            _ = try repo.replaceRound(corrected, inGame: Fx.gameA, resolution: truncate)
        }
        try expectFailedSaveRollsBack(repo, failures: failures, container: container) {
            _ = try repo.deleteLastRound(ofGame: Fx.gameA)
        }

        guard case .saved = try repo.replaceRound(corrected, inGame: Fx.gameA, resolution: truncate) else {
            Issue.record("La correction confirmée doit être enregistrée.")
            return
        }
        try expectFailedSaveRollsBack(repo, failures: failures, container: container) {
            _ = try repo.finishGame(id: Fx.gameA)
        }
        _ = try repo.finishGame(id: Fx.gameA)
        try expectFailedSaveRollsBack(repo, failures: failures, container: container) {
            _ = try repo.reopenGame(id: Fx.gameA)
        }
        try expectFailedSaveRollsBack(repo, failures: failures, container: container) {
            _ = try repo.archiveGame(id: Fx.gameA)
        }
        #expect(try repo.game(id: Fx.gameA).lifecycle == .finished)
        #expect(try repo.game(id: Fx.gameA).rounds.count == 2)
    }

    @Test("Vraie erreur SwiftData (store rouvert en lecture seule) : erreur remontée, rien n'est écrit")
    func readOnlyStoreReportsRealSaveError() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TableScoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appending(path: PersistenceController.storeFileName, directoryHint: .notDirectory)

        do {
            let writable = try PersistenceController.makeContainer(storage: .file(storeURL))
            _ = try SwiftDataGameRepository(container: writable)
                .createGame(id: Fx.gameA, participants: Fx.players(2), rules: .classic)
        }

        let readOnly = try PersistenceController.makeContainer(storage: .file(storeURL), allowsSave: false)
        let repo = SwiftDataGameRepository(container: readOnly)
        let before = try repo.game(id: Fx.gameA)
        let error = repositoryError {
            _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]), toGame: Fx.gameA)
        }
        #expect(error?.isWriteFailure == true)
        #expect(try repo.game(id: Fx.gameA) == before)

        let reopened = try PersistenceController.makeContainer(storage: .file(storeURL))
        #expect(try SwiftDataGameRepository(container: reopened).game(id: Fx.gameA) == before)
    }

    /// Échec injecté à la prochaine sauvegarde : l'opération doit échouer sans rien modifier,
    /// ni dans le contexte du dépôt, ni dans le store.
    private func expectFailedSaveRollsBack(
        _ repo: SwiftDataGameRepository,
        failures: SaveFailureSwitch,
        container: ModelContainer,
        _ operation: () throws -> Void
    ) throws {
        let before = try repo.game(id: Fx.gameA)
        failures.failNextSave = true
        let error = repositoryError(operation)
        #expect(error?.isWriteFailure == true)
        #expect(failures.failNextSave == false, "La sauvegarde doit avoir été tentée.")
        #expect(try repo.game(id: Fx.gameA) == before)
        #expect(try SwiftDataGameRepository(container: container).game(id: Fx.gameA) == before)
    }

    // MARK: Données corrompues

    @Test("Entrées illisibles ⇒ erreur typée, aucun crash")
    func unreadableEntries() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        try insertRawGame(into: container, rounds: [round], entriesPayloadOverride: Data("pas du JSON".utf8))

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).activeGame() }
        #expect(error == GameRepositoryError.corruptedData(
            gameID: Fx.gameA,
            .unreadablePayload(.roundEntries(roundID: round.id))
        ))
    }

    @Test("Version de format inconnue ⇒ erreur typée")
    func unsupportedFormatVersion() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        let futurePayload = Data(#"{"content":[],"formatVersion":99}"#.utf8)
        try insertRawGame(into: container, rounds: [round], entriesPayloadOverride: futurePayload)

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).game(id: Fx.gameA) }
        #expect(error == GameRepositoryError.corruptedData(
            gameID: Fx.gameA,
            .unsupportedFormatVersion(.roundEntries(roundID: round.id), version: 99)
        ))
    }

    @Test("Valeur de carte hors plage dans le JSON ⇒ rejet au décodage")
    func cardValueOutOfRangeIsRejected() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let cardEntry = try RoundEntry.cards(Fx.alice, grid: try Fx.cardGrid())
        let round = RoundInput(
            id: UUID(),
            index: 1,
            closingParticipantID: Fx.bob,
            entries: [cardEntry, .points(Fx.bob, rawScore: 20)]
        )
        let valid = try RecordMapper.entriesPayload(of: round)
        let json = String(decoding: valid, as: UTF8.self)
        #expect(json.contains(#""top":12"#))
        let tampered = Data(json.replacingOccurrences(of: #""top":12"#, with: #""top":13"#).utf8)
        try insertRawGame(into: container, rounds: [round], entriesPayloadOverride: tampered)

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).activeGame() }
        #expect(error == GameRepositoryError.corruptedData(
            gameID: Fx.gameA,
            .unreadablePayload(.roundEntries(roundID: round.id))
        ))
    }

    @Test("Grille incohérente avec le score brut ⇒ historique refusé par le moteur")
    func cardGridScoreMismatch() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let forged = RoundEntry(participantID: Fx.alice, rawScore: 99, source: .cards(try Fx.cardGrid()))
        let round = RoundInput(
            id: UUID(),
            index: 1,
            closingParticipantID: Fx.bob,
            entries: [forged, .points(Fx.bob, rawScore: 20)]
        )
        try insertRawGame(into: container, rounds: [round])

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).activeGame() }
        #expect(error?.historyReason == .cardGridScoreMismatch(participantID: Fx.alice, expected: 16, found: 99))
    }

    @Test("Un seul participant persisté ⇒ historique refusé")
    func invalidParticipantCount() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, participants: Fx.players(1))

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).activeGame() }
        #expect(error?.historyReason == .participantCountOutOfRange(count: 1))
    }

    @Test("Règles illisibles ⇒ erreur typée")
    func unreadableRules() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, rulesPayloadOverride: Data("{}".utf8))

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).activeGame() }
        #expect(error == GameRepositoryError.corruptedData(gameID: Fx.gameA, .unreadablePayload(.rules)))
    }

    @Test("Statut inconnu : partie listée comme illisible et supprimable")
    func unknownLifecycleIsListedAndDeletable() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, lifecycleRaw: "zombie")
        let repo = SwiftDataGameRepository(container: container)

        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames() == [
            .corrupted(id: Fx.gameA, updatedAt: rawDate, reason: .unknownLifecycle("zombie"))
        ])
        #expect(try repo.deleteGame(id: Fx.gameA))
        #expect(try repo.closedGames().isEmpty)
    }

    @Test("Deux parties actives : erreur typée, puis une création rétablit l'invariant")
    func multipleActiveGamesRecovery() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, id: Fx.gameA)
        try insertRawGame(into: container, id: Fx.gameB)
        let repo = SwiftDataGameRepository(container: container)

        let error = repositoryError { _ = try repo.activeGame() }
        #expect(error == GameRepositoryError.corruptedData(gameID: nil, .multipleActiveGames(count: 2)))

        _ = try repo.createGame(id: Fx.gameC, participants: Fx.players(2), rules: .classic)
        #expect(try repo.activeGame()?.id == Fx.gameC)
        #expect(try repo.game(id: Fx.gameA).isInterrupted)
        #expect(try repo.game(id: Fx.gameB).isInterrupted)
    }

    @Test("Partie active illisible : une création la range sans la perdre")
    func corruptedActiveGameIsArchivedOnCreate() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, participants: Fx.players(1))
        let repo = SwiftDataGameRepository(container: container)

        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)
        #expect(try repo.activeGame()?.id == Fx.gameB)
        let listings = try repo.closedGames()
        #expect(listings.map(\.id) == [Fx.gameA])
        guard case .corrupted(_, _, .invalidHistory)? = listings.first else {
            Issue.record("La partie illisible doit rester listée comme corrompue.")
            return
        }
    }

    @Test("Statut « terminée » alors que le moteur la dit en cours ⇒ corruption dédiée")
    func finishedButNotOverIsCorrupted() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, lifecycleRaw: GameLifecycle.finished.rawValue)
        let repo = SwiftDataGameRepository(container: container)

        let error = repositoryError { _ = try repo.game(id: Fx.gameA) }
        #expect(error == GameRepositoryError.corruptedData(gameID: Fx.gameA, .finishedGameNotOver))
        #expect(try repo.closedGames() == [
            .corrupted(id: Fx.gameA, updatedAt: rawDate, reason: .finishedGameNotOver)
        ])
    }

    @Test("Doublons d'enregistrements : même joueur ou même indice de manche ⇒ corruption")
    func duplicateRecordsAreCorrupted() throws {
        let duplicatedPlayers = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: duplicatedPlayers, participants: [
            Participant(id: Fx.alice, displayName: "Alice", displayOrder: 0),
            Participant(id: Fx.alice, displayName: "Alice bis", displayOrder: 1),
        ])
        let playerError = repositoryError { _ = try SwiftDataGameRepository(container: duplicatedPlayers).activeGame() }
        #expect(playerError?.historyReason == .duplicateParticipantID(Fx.alice))

        let duplicatedRounds = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: duplicatedRounds, rounds: [
            Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2]),
            Fx.round(1, closer: Fx.bob, [Fx.alice: 3, Fx.bob: 4]),
        ])
        let roundError = repositoryError { _ = try SwiftDataGameRepository(container: duplicatedRounds).activeGame() }
        #expect(roundError?.historyReason == .roundIndexMismatch(expected: 2, found: 1))
    }

    @Test("Charge utile au-delà de 64 Kio : rejet typé avant décodage")
    func oversizedPayloadIsRejected() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        let round = Fx.round(1, closer: Fx.alice, [Fx.alice: 1, Fx.bob: 2])
        let oversized = Data(repeating: 0x20, count: PayloadCoding.maxPayloadByteCount + 1)
        try insertRawGame(into: container, rounds: [round], entriesPayloadOverride: oversized)

        let error = repositoryError { _ = try SwiftDataGameRepository(container: container).activeGame() }
        #expect(error == GameRepositoryError.corruptedData(
            gameID: Fx.gameA,
            .payloadTooLarge(.roundEntries(roundID: round.id), byteCount: PayloadCoding.maxPayloadByteCount + 1)
        ))
    }

    @Test("Statut inconnu très long : valeur tronquée dans le diagnostic")
    func longUnknownLifecycleIsTruncated() throws {
        let container = try PersistenceController.makeContainer(storage: .inMemory)
        try insertRawGame(into: container, lifecycleRaw: String(repeating: "z", count: 200))
        let listings = try SwiftDataGameRepository(container: container).closedGames()
        #expect(listings == [
            .corrupted(id: Fx.gameA, updatedAt: rawDate, reason: .unknownLifecycle(String(repeating: "z", count: 32)))
        ])
    }

    // MARK: Configuration

    @Test("Choix du stockage : -uiTesting et tests hébergés seulement en Debug ; Release toujours sur disque")
    func storageDecisionIsPure() {
        typealias Context = PersistenceController.LaunchContext
        let hostedTests = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]

        #expect(PersistenceController.storage(for: Context(arguments: ["TableScore", "-uiTesting"], environment: [:], isDebugBuild: true)) == .inMemory)
        #expect(PersistenceController.storage(for: Context(arguments: ["TableScore"], environment: hostedTests, isDebugBuild: true)) == .inMemory)
        #expect(PersistenceController.storage(for: Context(arguments: ["TableScore"], environment: [:], isDebugBuild: true)) == .applicationSupport)
        // Release : aucun argument ni variable d'environnement ne détourne le stockage.
        #expect(PersistenceController.storage(for: Context(arguments: ["TableScore", "-uiTesting"], environment: hostedTests, isDebugBuild: false)) == .applicationSupport)
        #expect(PersistenceController.storage(for: Context(arguments: [], environment: [:], isDebugBuild: false)) == .applicationSupport)
    }

    @Test("Tests unitaires hébergés : le contexte courant n'ouvre jamais le vrai store")
    func hostedTestsNeverOpenRealStore() throws {
        let context = PersistenceController.LaunchContext.current
        #expect(context.isDebugBuild)
        #expect(PersistenceController.storage(for: context) == .inMemory)
        let repository = try PersistenceController.makeRepository(context: context)
        #expect(try repository.activeGame() == nil)
    }

    @Test("Configuration réelle (Application Support) : ni CloudKit ni conteneur partagé")
    func realConfigurationIsLocalOnly() throws {
        // Inspecte la configuration sans ouvrir le store.
        let configuration = try PersistenceController.makeConfiguration(
            storage: .applicationSupport,
            schema: PersistenceController.currentSchema
        )
        #expect(configuration.cloudKitContainerIdentifier == nil)
        #expect(configuration.groupAppContainerIdentifier == nil)
        #expect(!configuration.isStoredInMemoryOnly)
        #expect(configuration.allowsSave)
        #expect(configuration.url.standardizedFileURL == PersistenceController.defaultStoreURL.standardizedFileURL)
        #expect(PersistenceController.defaultStoreURL.lastPathComponent == "TableScore.store")

        let memory = try PersistenceController.makeConfiguration(storage: .inMemory, schema: PersistenceController.currentSchema)
        #expect(memory.isStoredInMemoryOnly)
        #expect(memory.cloudKitContainerIdentifier == nil)
        #expect(memory.groupAppContainerIdentifier == nil)
    }

    @Test("Schéma V1 figé : seule la source de vérité est persistée (aucun cumul ni score retenu)")
    func schemaStoresOnlySourceOfTruth() {
        let schema = Schema(versionedSchema: TableScoreSchemaV1.self)
        var attributesByEntity: [String: Set<String>] = [:]
        for entity in schema.entities {
            attributesByEntity[entity.name] = Set(entity.attributes.map(\.name))
        }
        // Toute modification de cette liste exige un nouveau `VersionedSchema` et une migration.
        #expect(attributesByEntity == [
            "GameRecord": [
                "gameID", "title", "lifecycleRaw", "rulesPayload",
                "createdAt", "updatedAt", "finishedAt", "archivedAt",
            ],
            "ParticipantRecord": ["participantID", "displayName", "displayOrder"],
            "RoundRecord": [
                "roundID", "roundIndex", "closingParticipantID", "entriesPayload", "createdAt", "modifiedAt",
            ],
        ])
    }

    // MARK: Insertion brute (données arbitraires, hors contrôles du dépôt)

    private let rawDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func insertRawGame(
        into container: ModelContainer,
        id: UUID = PersistenceFixtures.gameA,
        lifecycleRaw: String = GameLifecycle.active.rawValue,
        rulesPayloadOverride: Data? = nil,
        participants: [Participant] = PersistenceFixtures.players(2),
        rounds: [RoundInput] = [],
        entriesPayloadOverride: Data? = nil
    ) throws {
        let context = ModelContext(container)
        let rulesPayload = try rulesPayloadOverride ?? RecordMapper.rulesPayload(of: .classic)
        let game = GameRecord(
            gameID: id,
            title: nil,
            lifecycleRaw: lifecycleRaw,
            rulesPayload: rulesPayload,
            createdAt: rawDate,
            updatedAt: rawDate,
            finishedAt: nil,
            archivedAt: nil
        )
        context.insert(game)
        for participant in participants {
            let record = ParticipantRecord(
                participantID: participant.id,
                displayName: participant.displayName,
                displayOrder: participant.displayOrder
            )
            context.insert(record)
            record.game = game
        }
        for round in rounds {
            let payload = try entriesPayloadOverride ?? RecordMapper.entriesPayload(of: round)
            let record = RoundRecord(
                roundID: round.id,
                roundIndex: round.index,
                closingParticipantID: round.closingParticipantID,
                entriesPayload: payload,
                createdAt: rawDate,
                modifiedAt: rawDate
            )
            context.insert(record)
            record.game = game
        }
        try context.save()
    }
}

private extension GameRepositoryError {
    /// Cause élémentaire d'un historique persisté refusé par le moteur.
    var historyReason: ValidationError? {
        if case .corruptedData(_, .invalidHistory(let error)) = self { return error.underlyingReason }
        return nil
    }
}
