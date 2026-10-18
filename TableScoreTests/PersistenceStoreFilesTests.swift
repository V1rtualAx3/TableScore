import Foundation
import SwiftData
import Testing
import TableScoreKit
@testable import TableScore

/// Système de fichiers réel (dossier temporaire) qui enregistre les classes de protection
/// demandées et peut simuler des échecs.
final class RecordingStoreFileSystem: StoreFileSystem {
    struct SimulatedFailure: Error {}

    private let base = LocalStoreFileSystem()
    private(set) var protectionRequests: [(protection: FileProtectionType, url: URL)] = []
    private(set) var createdDirectories: [(protection: FileProtectionType, url: URL)] = []
    /// Renommage refusé si la fonction renvoie `true` (source, destination).
    var failsMove: (URL, URL) -> Bool = { _, _ in false }
    /// Création de dossier refusée si la fonction renvoie `true`.
    var failsCreateDirectory: (URL) -> Bool = { _ in false }

    func itemExists(at url: URL) -> Bool { base.itemExists(at: url) }
    func itemNames(in directory: URL) throws -> [String] { try base.itemNames(in: directory) }

    func createDirectory(at url: URL, protection: FileProtectionType) throws {
        if failsCreateDirectory(url) { throw SimulatedFailure() }
        createdDirectories.append((protection, url))
        try base.createDirectory(at: url, protection: protection)
    }

    func setProtection(_ protection: FileProtectionType, at url: URL) throws {
        protectionRequests.append((protection, url))
        try base.setProtection(protection, at: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        if failsMove(source, destination) { throw SimulatedFailure() }
        try base.moveItem(at: source, to: destination)
    }

    func removeItem(at url: URL) throws { try base.removeItem(at: url) }

    func requestedProtection(for url: URL) -> [FileProtectionType] {
        protectionRequests.filter { $0.url.standardizedFileURL == url.standardizedFileURL }.map(\.protection)
    }
}

/// Fichiers du store : protection, migration, effacement physique, mise de côté.
@Suite("Persistance : fichiers du store")
@MainActor
struct PersistenceStoreFilesTests {
    private typealias Fx = PersistenceFixtures

    /// Prénom témoin recherché octet par octet dans les fichiers (UTF-8, comme SQLite le stocke).
    private static let witnessName = "Qwertzuiopien"

    // MARK: Outils

    /// Dossier temporaire qui joue le rôle de `Application Support`.
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appending(path: "TableScoreStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Même disposition que l'app : `<base>/Store/TableScore.store`, ancien `<base>/TableScore.store`.
    private func makeLocation(in base: URL) -> StoreLocation {
        StoreLocation(
            storeURL: base.appending(path: "Store", directoryHint: .isDirectory)
                .appending(path: PersistenceController.storeFileName, directoryHint: .notDirectory),
            legacyStoreURL: base.appending(path: PersistenceController.storeFileName, directoryHint: .notDirectory)
        )
    }

    private func witnessPlayers() -> [Participant] {
        [
            Participant(id: Fx.alice, displayName: Self.witnessName, displayOrder: 0),
            Participant(id: Fx.bob, displayName: "Bob", displayOrder: 1),
        ]
    }

    private func populate(_ repo: any GameRepository) throws {
        _ = try repo.createGame(id: Fx.gameA, participants: witnessPlayers(), rules: .classic)
        _ = try repo.appendRound(Fx.round(1, closer: Fx.alice, [Fx.alice: 3, Fx.bob: 8]), toGame: Fx.gameA)
    }

    /// Chemins (relatifs à `base`) des fichiers contenant `needle`, fichiers cachés compris.
    private func files(containing needle: String, under base: URL) -> [String] {
        let bytes = Data(needle.utf8)
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var matches: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = FileManager.default.contents(atPath: url.path) else { continue }
            if data.range(of: bytes) != nil { matches.append(url.lastPathComponent) }
        }
        return matches
    }

    private func isStorageFailure(_ error: GameRepositoryError?, _ operation: StorageOperation) -> Bool {
        if case .storageFailure(let failed, _) = error { return failed == operation }
        return false
    }

    private func names(in directory: URL) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
    }

    // MARK: Noms et plans (pur)

    @Test("Éléments du store : annexes d'abord, base en dernier")
    func storeItemOrder() {
        #expect(StoreFiles.storeItemNames(storeFileName: "TableScore.store") == [
            "TableScore.store-wal", "TableScore.store-shm", ".TableScore_SUPPORT", "TableScore.store",
        ])
    }

    @Test("Noms mis de côté : TableScore-illisible-<horodatage>.store(-wal/-shm)")
    func setAsideNames() {
        let date = Date(timeIntervalSince1970: 1_792_337_400) // 2026-10-18 15:30:00 UTC
        #expect(StoreFiles.setAsideStamp(for: date) == "20261018-153000")
        let stamp = "20261018-153000"
        #expect(StoreFiles.setAsideName(for: "TableScore.store", storeFileName: "TableScore.store", stamp: stamp)
            == "TableScore-illisible-20261018-153000.store")
        #expect(StoreFiles.setAsideName(for: "TableScore.store-wal", storeFileName: "TableScore.store", stamp: stamp)
            == "TableScore-illisible-20261018-153000.store-wal")
        #expect(StoreFiles.setAsideName(for: "TableScore.store-shm", storeFileName: "TableScore.store", stamp: stamp)
            == "TableScore-illisible-20261018-153000.store-shm")
        #expect(StoreFiles.setAsideName(for: ".TableScore_SUPPORT", storeFileName: "TableScore.store", stamp: stamp)
            == ".TableScore-illisible-20261018-153000_SUPPORT")
        #expect(StoreFiles.setAsideName(for: "autre.txt", storeFileName: "TableScore.store", stamp: stamp) == nil)
        #expect(StoreFiles.setAsideName(for: "TableScore.store-journal-x", storeFileName: "TableScore.store", stamp: stamp) == nil)
    }

    @Test("Mise de côté : jamais de destination existante (suffixe -2)")
    func setAsideAvoidsCollisions() {
        let date = Date(timeIntervalSince1970: 1_792_337_400)
        let renames = StoreFiles.setAsideRenames(
            existingNames: ["TableScore.store", "TableScore.store-wal", "TableScore-illisible-20261018-153000.store"],
            storeFileName: "TableScore.store",
            date: date
        )
        #expect(renames.map(\.from) == ["TableScore.store-wal", "TableScore.store"])
        #expect(renames.map(\.to) == [
            "TableScore-illisible-20261018-153000-2.store-wal", "TableScore-illisible-20261018-153000-2.store",
        ])
        #expect(StoreFiles.setAsideRenames(existingNames: ["autre"], storeFileName: "TableScore.store", date: date).isEmpty)
    }

    @Test("Plan de migration : base en dernier, jamais d'écrasement")
    func legacyMigrationPlan() {
        let name = "TableScore.store"
        #expect(StoreFiles.legacyMigration(legacyNames: [], storeNames: [], storeFileName: name) == .nothingToMove)
        #expect(StoreFiles.legacyMigration(
            legacyNames: [name, name + "-wal", name + "-shm", "autre"], storeNames: [], storeFileName: name
        ) == .move([name + "-wal", name + "-shm", name]))
        // Reprise après interruption : -wal déjà déplacé.
        #expect(StoreFiles.legacyMigration(
            legacyNames: [name, name + "-shm"], storeNames: [name + "-wal"], storeFileName: name
        ) == .move([name + "-shm", name]))
        // Nouvelle base présente : l'ancienne n'est jamais déplacée par-dessus.
        #expect(StoreFiles.legacyMigration(legacyNames: [name], storeNames: [name], storeFileName: name) == .nothingToMove)
        // Annexe aux deux emplacements : rien n'est déplacé.
        #expect(StoreFiles.legacyMigration(
            legacyNames: [name, name + "-wal"], storeNames: [name + "-wal"], storeFileName: name
        ) == .conflict(name + "-wal"))
        // Annexes orphelines sans ancienne base : ignorées.
        #expect(StoreFiles.legacyMigration(legacyNames: [name + "-wal"], storeNames: [], storeFileName: name) == .nothingToMove)
    }

    @Test("Restes effaçables : uniquement le store et ses fichiers mis de côté")
    func erasableNames() {
        let names = ["TableScore.store", "TableScore.store-wal", "TableScore-illisible-1.store", ".TableScore-illisible-1_SUPPORT",
                     "Store", "UITests", "TableScore-uitests.store", "autre.txt"]
        #expect(StoreFiles.legacyErasableNames(in: names, storeFileName: "TableScore.store") == [
            ".TableScore-illisible-1_SUPPORT", "TableScore-illisible-1.store", "TableScore.store", "TableScore.store-wal",
        ])
        #expect(StoreFiles.leftoverErasureNames(in: ["Store", "Store.effacement-A", "UITests.effacement-B", "Storex"], directoryName: "Store")
            == ["Store.effacement-A"])
    }

    @Test("Emplacement de l'app : dossier dédié Store/, ancien emplacement à la racine")
    func appLocation() throws {
        let location = try #require(PersistenceController.storeLocation(for: .applicationSupport))
        #expect(location.storeURL == PersistenceController.defaultStoreURL)
        #expect(location.directory.lastPathComponent == PersistenceController.storeDirectoryName)
        #expect(location.fileName == "TableScore.store")
        #expect(location.legacyStoreURL == PersistenceController.legacyStoreURL)
        #expect(location.legacyStoreURL?.deletingLastPathComponent().standardizedFileURL
            == location.directory.deletingLastPathComponent().standardizedFileURL)
        #expect(PersistenceController.storeLocation(for: .inMemory) == nil)
    }

    // MARK: Protection

    @Test("Classe retenue : complete until first user authentication")
    func chosenProtection() {
        #expect(StoreFiles.protection == .completeUntilFirstUserAuthentication)
    }

    @Test("Préparation : classe demandée à la création du dossier, au dossier et aux fichiers du store")
    func prepareRequestsProtection() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let fileSystem = RecordingStoreFileSystem()

        let repo = try PersistenceController.makeRepository(location: location, fileSystem: fileSystem)
        try populate(repo)
        #expect(fileSystem.createdDirectories.contains {
            $0.url.standardizedFileURL == location.directory.standardizedFileURL
                && $0.protection == .completeUntilFirstUserAuthentication
        })
        #expect(fileSystem.requestedProtection(for: location.directory) == [.completeUntilFirstUserAuthentication])

        // Relance : la base existante reçoit explicitement la classe. (La valeur renvoyée n'est pas
        // vérifiée : le simulateur peut refuser l'attribut, ce qui ne bloque pas l'ouverture.)
        let relaunch = RecordingStoreFileSystem()
        _ = try StoreFiles.prepare(location, fileSystem: relaunch)
        #expect(relaunch.requestedProtection(for: location.storeURL) == [.completeUntilFirstUserAuthentication])
        #expect(relaunch.requestedProtection(for: location.directory) == [.completeUntilFirstUserAuthentication])
    }

    /// Attribut effectif : le simulateur n'applique pas la protection des données et peut ne pas
    /// renvoyer l'attribut. Si l'attribut est présent, il doit valoir la classe choisie ; s'il est
    /// absent, ce test ne prouve rien (la preuve est alors `prepareRequestsProtection`, et le
    /// contrôle effectif reste à faire sur appareil).
    @Test("Attribut relu sur le dossier (tolérant sur simulateur)")
    func protectionAttributeReadBack() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        try StoreFiles.prepare(location, fileSystem: LocalStoreFileSystem())
        let attributes = try FileManager.default.attributesOfItem(atPath: location.directory.path)
        let expected = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        let raw = attributes[.protectionKey]
        let value = (raw as? FileProtectionType)?.rawValue ?? (raw as? String)
        #if targetEnvironment(simulator)
        if let value { #expect(value == expected) }
        #else
        #expect(value == expected)
        #endif
    }

    // MARK: Migration

    @Test("Migration : l'ancien store est déplacé avec ses annexes et reste lisible")
    func migratesLegacyStore() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let legacyURL = try #require(location.legacyStoreURL)

        let saved: SavedGame
        do {
            let legacy = SwiftDataGameRepository(container: try PersistenceController.makeContainer(storage: .file(legacyURL)))
            try populate(legacy)
            saved = try legacy.game(id: Fx.gameA)
        }
        #expect(names(in: base).contains("TableScore.store"))

        let repo = try PersistenceController.makeRepository(location: location)
        #expect(try repo.game(id: Fx.gameA) == saved)
        #expect(!names(in: base).contains("TableScore.store"))
        #expect(!names(in: base).contains("TableScore.store-wal"))
        #expect(names(in: location.directory).contains("TableScore.store"))
    }

    @Test("Migration interrompue : rien n'est ouvert, reprise au lancement suivant sans perte")
    func interruptedMigrationResumes() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let legacyURL = try #require(location.legacyStoreURL)

        let saved: SavedGame
        do {
            let legacy = SwiftDataGameRepository(container: try PersistenceController.makeContainer(storage: .file(legacyURL)))
            try populate(legacy)
            saved = try legacy.game(id: Fx.gameA)
        }

        let failing = RecordingStoreFileSystem()
        failing.failsMove = { source, _ in source.lastPathComponent == "TableScore.store" }
        let error = repositoryError { _ = try PersistenceController.makeRepository(location: location, fileSystem: failing) }
        #expect(isStorageFailure(error, .setup))
        #expect(names(in: base).contains("TableScore.store"))
        #expect(!names(in: location.directory).contains("TableScore.store"))

        let repo = try PersistenceController.makeRepository(location: location)
        #expect(try repo.game(id: Fx.gameA) == saved)
    }

    // MARK: Effacement physique

    @Test("Supprimer toutes les données : aucun prénom ne subsiste dans les fichiers, store recréé")
    func deleteAllErasesFiles() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let repo = try PersistenceController.makeRepository(location: location)
        try populate(repo)
        // Témoin : le prénom est bien écrit sur disque (sinon le test ne prouverait rien).
        #expect(!files(containing: Self.witnessName, under: base).isEmpty)

        try repo.deleteAllGames()

        #expect(files(containing: Self.witnessName, under: base).isEmpty)
        #expect(repo.isStoreAvailable)
        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames().isEmpty)
        #expect(names(in: base).allSatisfy { !$0.contains(StoreFiles.erasureMarker) })
        #expect(names(in: location.directory).contains("TableScore.store"))

        // Le dépôt (même instance) reste utilisable et persiste sur le nouveau store.
        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)
        let reopened = SwiftDataGameRepository(container: try PersistenceController.makeContainer(storage: .file(location.storeURL)))
        #expect(try reopened.activeGame()?.id == Fx.gameB)
    }

    @Test("Supprimer toutes les données : restes de l'ancien emplacement et données mises de côté effacés")
    func deleteAllErasesLegacyLeftovers() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let repo = try PersistenceController.makeRepository(location: location)
        try populate(repo)
        let witness = Data(Self.witnessName.utf8)
        let unrelated = base.appending(path: "autre.txt", directoryHint: .notDirectory)
        for name in ["TableScore-illisible-1.store", "TableScore.store-wal"] {
            #expect(FileManager.default.createFile(atPath: base.appending(path: name).path, contents: witness))
        }
        #expect(FileManager.default.createFile(atPath: unrelated.path, contents: witness))

        try repo.deleteAllGames()

        #expect(files(containing: Self.witnessName, under: base) == ["autre.txt"])
        #expect(names(in: base) == ["Store", "autre.txt"])
    }

    @Test("Effacement impossible (renommage refusé) : parties supprimées, store rouvert, erreur honnête")
    func eraseFailureKeepsStoreUsable() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let fileSystem = RecordingStoreFileSystem()
        let repo = try PersistenceController.makeRepository(location: location, fileSystem: fileSystem)
        try populate(repo)
        fileSystem.failsMove = { source, _ in source.standardizedFileURL == location.directory.standardizedFileURL }

        let error = repositoryError { try repo.deleteAllGames() }
        #expect(isStorageFailure(error, .eraseFiles))
        #expect(error?.gamesWereDeletedBeforeFailure == true)
        #expect(repo.isStoreAvailable)
        #expect(try repo.activeGame() == nil)
        #expect(try repo.closedGames().isEmpty)

        // Nouvel essai : l'effacement aboutit.
        fileSystem.failsMove = { _, _ in false }
        try repo.deleteAllGames()
        #expect(files(containing: Self.witnessName, under: base).isEmpty)
    }

    @Test("Recréation impossible : store indisponible (erreurs, jamais de liste vide), reprise ensuite")
    func recreationFailureMakesStoreUnavailable() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let fileSystem = RecordingStoreFileSystem()
        let repo = try PersistenceController.makeRepository(location: location, fileSystem: fileSystem)
        try populate(repo)
        fileSystem.failsCreateDirectory = { $0.standardizedFileURL == location.directory.standardizedFileURL }

        let error = repositoryError { try repo.deleteAllGames() }
        #expect(isStorageFailure(error, .reopenAfterErase))
        #expect(error?.gamesWereDeletedBeforeFailure == true)
        #expect(!repo.isStoreAvailable)
        #expect(files(containing: Self.witnessName, under: base).isEmpty)
        let read = repositoryError { _ = try repo.activeGame() }
        #expect(isStorageFailure(read, .read))
        let write = repositoryError { _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic) }
        #expect(write != nil)

        fileSystem.failsCreateDirectory = { _ in false }
        try repo.deleteAllGames()
        #expect(repo.isStoreAvailable)
        #expect(try repo.activeGame() == nil)
        _ = try repo.createGame(id: Fx.gameB, participants: Fx.players(2), rules: .classic)
    }

    @Test("Paramètres : effacement inachevé ⇒ erreur affichée, pas de succès, écrans rafraîchis")
    func settingsReportsPartialErase() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        let fileSystem = RecordingStoreFileSystem()
        let repo = try PersistenceController.makeRepository(location: location, fileSystem: fileSystem)
        try populate(repo)
        fileSystem.failsMove = { source, _ in source.standardizedFileURL == location.directory.standardizedFileURL }

        let model = SettingsModel(repository: repo)
        model.beginDeletion()
        model.continueDeletion()
        #expect(model.confirmDeleteAll())
        #expect(model.didDeleteAll == false)
        #expect(model.errorMessage == GameRepositoryError.storageFailure(.eraseFiles, message: "").userFacingMessage)
    }

    @Test("Messages d'effacement : sans chemin ni donnée saisie")
    func eraseMessagesAreSafe() {
        for operation in [StorageOperation.eraseFiles, .reopenAfterErase] {
            let message = GameRepositoryError.storageFailure(operation, message: "/private/Alice").userFacingMessage
            #expect(!message.isEmpty)
            #expect(!message.contains("/"))
            #expect(!message.contains("Alice"))
        }
        #expect(GameRepositoryError.storageFailure(.write, message: "").gamesWereDeletedBeforeFailure == false)
    }

    // MARK: Mise de côté d'un store illisible

    @Test("Mise de côté : fichiers renommés dans le même dossier, rien n'est supprimé, store vide recréé")
    func setAsideRenamesWithoutDeleting() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        let garbage = Data("pas une base SQLite".utf8)
        for suffix in ["", "-wal", "-shm"] {
            #expect(FileManager.default.createFile(atPath: location.storeURL.path + suffix, contents: garbage + Data(suffix.utf8)))
        }
        let unrelated = location.directory.appending(path: "autre.txt", directoryHint: .notDirectory)
        #expect(FileManager.default.createFile(atPath: unrelated.path, contents: garbage))

        let date = Date(timeIntervalSince1970: 1_792_337_400)
        let renamed = try StoreFiles.setAside(location, fileSystem: LocalStoreFileSystem(), date: date)

        #expect(renamed == 3)
        let prefix = "TableScore-illisible-20261018-153000.store"
        #expect(names(in: location.directory) == [prefix, prefix + "-wal", prefix + "-shm", "autre.txt"])
        for suffix in ["", "-wal", "-shm"] {
            let url = location.directory.appending(path: prefix + suffix, directoryHint: .notDirectory)
            #expect(FileManager.default.contents(atPath: url.path) == garbage + Data(suffix.utf8))
        }

        let repo = try PersistenceController.makeRepository(location: location)
        #expect(try repo.activeGame() == nil)
        #expect(names(in: location.directory).isSuperset(of: [prefix, prefix + "-wal", prefix + "-shm", "autre.txt"]))
    }

    @Test("Store illisible : ouverture en erreur, puis mise de côté et nouveau store vide")
    func unreadableStoreCanBeSetAside() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: location.storeURL.path, contents: Data(repeating: 0x5A, count: 4096)))

        #expect(repositoryError { _ = try PersistenceController.makeRepository(location: location) } != nil)

        #expect(try PersistenceController.setAsideUnreadableStore(
            storage: .file(location.storeURL),
            date: Date(timeIntervalSince1970: 1_792_337_400)
        ) >= 1)
        #expect(names(in: location.directory).contains("TableScore-illisible-20261018-153000.store"))
        let repo = try PersistenceController.makeRepository(location: location)
        #expect(try repo.activeGame() == nil)
    }

    @Test("Mise de côté en échec : renommages annulés, rien n'est supprimé")
    func setAsideRollsBack() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] {
            #expect(FileManager.default.createFile(atPath: location.storeURL.path + suffix, contents: Data([1])))
        }
        let before = names(in: location.directory)
        let fileSystem = RecordingStoreFileSystem()
        fileSystem.failsMove = { source, _ in source.lastPathComponent == "TableScore.store" }

        let error = repositoryError { _ = try StoreFiles.setAside(location, fileSystem: fileSystem, date: Date()) }
        #expect(error != nil)
        #expect(names(in: location.directory) == before)
    }

    @Test("Mise de côté : ancien emplacement compris ; sans fichier, rien à faire")
    func setAsideIncludesLegacyAndIsNoOpWhenEmpty() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let location = makeLocation(in: base)
        #expect(try StoreFiles.setAside(location, fileSystem: LocalStoreFileSystem(), date: Date()) == 0)

        #expect(FileManager.default.createFile(atPath: base.appending(path: "TableScore.store").path, contents: Data([1])))
        let date = Date(timeIntervalSince1970: 1_792_337_400)
        #expect(try StoreFiles.setAside(location, fileSystem: LocalStoreFileSystem(), date: date) == 1)
        #expect(names(in: base).contains("TableScore-illisible-20261018-153000.store"))
        #expect(!names(in: base).contains("TableScore.store"))
    }

    @Test("Mise de côté proposée seulement pour un stockage fichier")
    func setAsideOfferedOnlyForFileStorage() throws {
        typealias Context = PersistenceController.LaunchContext
        // Release : toujours le store de l'app.
        #expect(AppBootstrap.canSetAsideUnreadableData(context: Context(arguments: [], environment: [:], isDebugBuild: false)))
        // Tests unitaires hébergés (Debug) : mémoire.
        if PersistenceController.isDebugBuild {
            #expect(!AppBootstrap.canSetAsideUnreadableData(context: .current))
        }
        #expect(try PersistenceController.setAsideUnreadableStore(storage: .inMemory) == 0)
    }
}
