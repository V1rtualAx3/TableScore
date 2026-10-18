import Foundation
import SwiftData

/// Emplacement du stockage local.
enum PersistenceStorage: Sendable, Hashable {
    /// Fichier `Store/TableScore.store` dans `Library/Application Support` du conteneur privé de
    /// l'app (dossier dédié ; ancien emplacement `Application Support/TableScore.store` migré).
    case applicationSupport
    /// Mémoire volatile : tests unitaires, tests UI (`-uiTesting`), previews.
    case inMemory
    /// Fichier explicite (tests de relance sur disque). Son dossier doit être dédié au store.
    case file(URL)
}

/// Fabrique du `ModelContainer` de TableScore : **local uniquement**.
///
/// - `cloudKitDatabase: .none` : aucune synchronisation, même si une capability apparaissait un jour.
/// - `groupContainer: .none` / URL explicite : jamais de conteneur partagé (App Group).
/// - Fichiers (voir `StoreFiles`) : dossier dédié `Application Support/Store/`, classe de
///   protection `NSFileProtectionCompleteUntilFirstUserAuthentication` appliquée explicitement au
///   dossier (héritée par la base, `-wal` et `-shm`) et aux fichiers existants : chiffrés par le
///   système tant que l'appareil n'a pas été déverrouillé une première fois après démarrage,
///   lisibles ensuite (`.complete` ferait échouer une écriture en cours au verrouillage). Aucun
///   chiffrement applicatif supplémentaire n'est mis en œuvre ni promis. Attribut effectif
///   vérifiable sur appareil uniquement (le simulateur n'applique pas la protection des données).
/// - Sauvegardes système de l'appareil : gérées par iOS, hors du contrôle de l'app ; aucune
///   synchronisation n'est activée par le code.
///
/// Ouverture : `AppBootstrap` (`makeRepository(context: .current)`) ; en cas d'échec, une erreur
/// (`userFacingMessage`) est affichée, jamais de `fatalError`.
enum PersistenceController {
    #if DEBUG
    /// Argument de lancement des tests UI : stockage en mémoire (builds Debug uniquement).
    static let uiTestingLaunchArgument = "-uiTesting"
    /// Argument de lancement (Debug uniquement) : store FICHIER dédié aux tests UI de relance.
    static let uiTestingPersistentStoreLaunchArgument = "-uiTestingPersistentStore"
    /// Argument de lancement (Debug uniquement) : supprime le store dédié avant ouverture.
    static let resetUITestStoreLaunchArgument = "-resetUITestStore"
    static let uiTestStoreFileName = "TableScore-uitests.store"
    /// Variables d'environnement posées par XCTest dans l'app hôte des tests unitaires.
    static let hostedTestEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
    #endif
    static let storeFileName = "TableScore.store"
    /// Dossier dédié au store dans `Application Support`.
    static let storeDirectoryName = "Store"

    /// Contexte de lancement, injecté pour rendre le choix du stockage testable.
    struct LaunchContext: Sendable, Hashable {
        var arguments: [String]
        var environment: [String: String]
        var isDebugBuild: Bool

        static var current: LaunchContext {
            LaunchContext(
                arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment,
                isDebugBuild: PersistenceController.isDebugBuild
            )
        }
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Choix pur du stockage (tout le code des tests UI est sous `#if DEBUG`, absent des binaires Release) :
    /// - Release : **toujours** `applicationSupport` (aucun argument ne peut détourner le stockage
    ///   d'une app distribuée) ;
    /// - Debug + `-uiTestingPersistentStore` : store fichier **dédié** aux tests UI
    ///   (`Application Support/UITests/TableScore-uitests.store`, jamais le vrai store) ; les
    ///   fixtures `-seed` ne s'y appliquent pas (elles exigent la mémoire) ;
    /// - Debug + `-uiTesting` : mémoire (tests UI ; le futur `-seed` suivra la même règle) ;
    /// - Debug + app hôte de tests unitaires (variables XCTest) : mémoire, le vrai store n'est
    ///   jamais ouvert par les tests ;
    /// - sinon `applicationSupport`.
    static func storage(for context: LaunchContext) -> PersistenceStorage {
        #if DEBUG
        guard context.isDebugBuild else { return .applicationSupport }
        if context.arguments.contains(uiTestingPersistentStoreLaunchArgument) {
            return .file(uiTestStoreURL)
        }
        if context.arguments.contains(uiTestingLaunchArgument) { return .inMemory }
        if hostedTestEnvironmentKeys.contains(where: { context.environment[$0] != nil }) { return .inMemory }
        return .applicationSupport
        #else
        // Release : le contexte (arguments, environnement) est ignoré, y compris les chemins de test.
        return .applicationSupport
        #endif
    }

    /// Emplacement du stockage persistant, dans le conteneur privé de l'application.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory
            .appending(path: storeDirectoryName, directoryHint: .isDirectory)
            .appending(path: storeFileName, directoryHint: .notDirectory)
    }

    /// Ancien emplacement (Lots 1 à 3), migré par déplacement vers `defaultStoreURL`.
    static var legacyStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: storeFileName, directoryHint: .notDirectory)
    }

    /// Emplacement fichier d'un stockage (`nil` en mémoire). Seul le store de l'app migre
    /// l'ancien emplacement.
    static func storeLocation(for storage: PersistenceStorage) -> StoreLocation? {
        switch storage {
        case .inMemory:
            return nil
        case .applicationSupport:
            return StoreLocation(storeURL: defaultStoreURL, legacyStoreURL: legacyStoreURL)
        case .file(let url):
            return StoreLocation(storeURL: url)
        }
    }

    #if DEBUG
    /// Store fichier dédié aux tests UI de relance (distinct de `defaultStoreURL`).
    static var uiTestStoreURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "UITests", directoryHint: .isDirectory)
            .appending(path: uiTestStoreFileName, directoryHint: .notDirectory)
    }

    /// Supprime le store dédié aux tests UI si `-resetUITestStore` est présent. Sans effet en
    /// Release, ou si le stockage choisi n'est pas le store dédié (le vrai store n'est jamais touché).
    static func resetUITestStoreIfRequested(context: LaunchContext) throws(GameRepositoryError) {
        guard context.isDebugBuild,
              context.arguments.contains(resetUITestStoreLaunchArgument),
              case .file(let url) = storage(for: context),
              url == uiTestStoreURL else { return }
        try removeStoreFiles(at: url)
    }

    /// Supprime le fichier SQLite et ses fichiers annexes `-wal` / `-shm` (absents : sans erreur).
    static func removeStoreFiles(at url: URL) throws(GameRepositoryError) {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            let candidate = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            do {
                try fileManager.removeItem(at: candidate)
            } catch {
                throw GameRepositoryError.storageFailure(.setup, message: ErrorDiagnostics.summary(of: error))
            }
        }
    }
    #endif

    static var currentSchema: Schema {
        Schema(versionedSchema: TableScoreSchemaV1.self)
    }

    /// Configuration exacte utilisée par `makeContainer` (inspectable sans ouvrir le store).
    /// `allowsSave: false` n'est utilisé que par les tests (store en lecture seule).
    static func makeConfiguration(
        storage: PersistenceStorage,
        schema: Schema,
        allowsSave: Bool = true
    ) throws(GameRepositoryError) -> ModelConfiguration {
        switch storage {
        case .inMemory:
            // Nom unique : chaque conteneur en mémoire est isolé des autres.
            return ModelConfiguration(
                "TableScore-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: allowsSave,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        case .applicationSupport:
            return fileConfiguration(url: defaultStoreURL, schema: schema, allowsSave: allowsSave)
        case .file(let url):
            return fileConfiguration(url: url, schema: schema, allowsSave: allowsSave)
        }
    }

    /// Conteneur du stockage demandé. Store fichier : dossier préparé avant ouverture
    /// (`StoreFiles.prepare` : protection, migration de l'ancien emplacement).
    static func makeContainer(
        storage: PersistenceStorage,
        allowsSave: Bool = true,
        fileSystem: any StoreFileSystem = LocalStoreFileSystem()
    ) throws(GameRepositoryError) -> ModelContainer {
        guard let location = storeLocation(for: storage) else {
            return try openContainer(storage: storage, allowsSave: allowsSave)
        }
        return try openFileContainer(location, allowsSave: allowsSave, fileSystem: fileSystem)
    }

    /// Lancement d'un store fichier : préparation (effacement interrompu rejoué, sinon migration),
    /// ouverture, puis retrait du marqueur d'effacement **après** ouverture réussie. Si le marqueur
    /// ne peut pas être retiré, l'ouverture est refusée : sinon le prochain lancement effacerait
    /// les parties créées entre-temps.
    private static func openFileContainer(
        _ location: StoreLocation,
        allowsSave: Bool,
        fileSystem: any StoreFileSystem
    ) throws(GameRepositoryError) -> ModelContainer {
        try StoreFiles.prepare(location, fileSystem: fileSystem, mode: .launch)
        let container = try openContainer(storage: .file(location.storeURL), allowsSave: allowsSave)
        try StoreFiles.removeErasureMarker(for: location, fileSystem: fileSystem)
        return container
    }

    /// Après « Supprimer toutes les données » : recrée le store vide dans un dossier neuf (ou rouvre
    /// l'ancien, déjà vidé, si son dossier n'a pas pu être effacé). Sans migration : l'ancien
    /// emplacement vient d'être vidé ; un reste éventuel ne doit pas être réimporté.
    static func makeEmptyFileContainer(
        at location: StoreLocation,
        fileSystem: any StoreFileSystem
    ) throws(GameRepositoryError) -> ModelContainer {
        try StoreFiles.prepare(location, fileSystem: fileSystem, mode: .afterErase)
        return try openContainer(storage: .file(location.storeURL), allowsSave: true)
    }

    private static func openContainer(
        storage: PersistenceStorage,
        allowsSave: Bool
    ) throws(GameRepositoryError) -> ModelContainer {
        let schema = currentSchema
        let configuration = try makeConfiguration(storage: storage, schema: schema, allowsSave: allowsSave)
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: TableScoreMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            // Seul cas où « Mettre de côté » est proposé : le store existe mais ne s'ouvre pas.
            throw GameRepositoryError.storageFailure(.openStore, message: ErrorDiagnostics.summary(of: error))
        }
    }

    /// Dépôt de l'application selon le contexte de lancement (voir `storage(for:)`).
    @MainActor
    static func makeRepository(
        context: LaunchContext = .current,
        fileSystem: any StoreFileSystem = LocalStoreFileSystem()
    ) throws(GameRepositoryError) -> SwiftDataGameRepository {
        #if DEBUG
        try resetUITestStoreIfRequested(context: context)
        #endif
        return try makeRepository(storage: storage(for: context), fileSystem: fileSystem)
    }

    /// Dépôt d'un stockage donné ; un store fichier peut être effacé physiquement
    /// (`deleteAllGames`, voir `SwiftDataGameRepository`).
    @MainActor
    static func makeRepository(
        storage: PersistenceStorage,
        fileSystem: any StoreFileSystem = LocalStoreFileSystem()
    ) throws(GameRepositoryError) -> SwiftDataGameRepository {
        guard let location = storeLocation(for: storage) else {
            return SwiftDataGameRepository(container: try makeContainer(storage: storage, fileSystem: fileSystem))
        }
        return try makeRepository(location: location, fileSystem: fileSystem)
    }

    /// Dépôt d'un store fichier : dossier préparé (protection, migration), puis ouverture.
    @MainActor
    static func makeRepository(
        location: StoreLocation,
        fileSystem: any StoreFileSystem = LocalStoreFileSystem()
    ) throws(GameRepositoryError) -> SwiftDataGameRepository {
        let container = try openFileContainer(location, allowsSave: true, fileSystem: fileSystem)
        return SwiftDataGameRepository(
            container: container,
            fileStore: SwiftDataGameRepository.FileStore(location: location, fileSystem: fileSystem)
        )
    }

    /// Met de côté un store illisible (renommage, jamais de suppression ; voir `StoreFiles.setAside`).
    /// Sans effet en mémoire. Renvoie le nombre d'éléments renommés.
    @discardableResult
    static func setAsideUnreadableStore(
        storage: PersistenceStorage,
        fileSystem: any StoreFileSystem = LocalStoreFileSystem(),
        date: Date = Date()
    ) throws(GameRepositoryError) -> Int {
        guard let location = storeLocation(for: storage) else { return 0 }
        return try StoreFiles.setAside(location, fileSystem: fileSystem, date: date)
    }

    private static func fileConfiguration(
        url: URL,
        schema: Schema,
        allowsSave: Bool
    ) -> ModelConfiguration {
        // Aucun accès disque ici : le dossier est créé et protégé par `StoreFiles.prepare`
        // (via le système de fichiers injecté) avant toute ouverture.
        ModelConfiguration(
            "TableScore",
            schema: schema,
            url: url,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
    }
}
