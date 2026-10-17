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

    // MARK: Configuration

    @Test("Arguments de lancement : -uiTesting ⇒ mémoire, sinon Application Support")
    func launchArgumentsSelectStorage() throws {
        #expect(PersistenceController.storage(forLaunchArguments: ["TableScore", "-uiTesting"]) == .inMemory)
        #expect(PersistenceController.storage(forLaunchArguments: ["TableScore"]) == .applicationSupport)

        let url = PersistenceController.defaultStoreURL
        #expect(url.lastPathComponent == "TableScore.store")
        #expect(url.path(percentEncoded: false).hasPrefix(URL.applicationSupportDirectory.path(percentEncoded: false)))

        let uiTestRepository = try PersistenceController.makeRepository(launchArguments: ["-uiTesting"])
        #expect(try uiTestRepository.activeGame() == nil)
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
