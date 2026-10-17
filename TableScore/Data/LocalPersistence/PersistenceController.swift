import Foundation
import SwiftData

/// Emplacement du stockage local.
enum PersistenceStorage: Sendable, Hashable {
    /// Fichier `TableScore.store` dans `Library/Application Support` du conteneur privé de l'app.
    case applicationSupport
    /// Mémoire volatile : tests unitaires, tests UI (`-uiTesting`), previews.
    case inMemory
    /// Fichier explicite (tests de relance sur disque).
    case file(URL)
}

/// Fabrique du `ModelContainer` de TableScore : **local uniquement**.
///
/// - `cloudKitDatabase: .none` : aucune synchronisation, même si une capability apparaissait un jour.
/// - `groupContainer: .none` / URL explicite : jamais de conteneur partagé (App Group).
/// - Protection des fichiers : aucun réglage spécifique ; le fichier SQLite (et ses fichiers
///   `-wal`/`-shm`) hérite de la classe par défaut d'iOS pour les données d'app,
///   `NSFileProtectionCompleteUntilFirstUserAuthentication` : chiffré par le système tant que
///   l'appareil n'a pas été déverrouillé une première fois après démarrage, lisible ensuite.
///   Aucun chiffrement applicatif supplémentaire n'est mis en œuvre ni promis. Comportement non
///   vérifiable sur simulateur : à contrôler sur appareil (Lot 4).
/// - Sauvegardes système de l'appareil : gérées par iOS, hors du contrôle de l'app ; aucune
///   synchronisation n'est activée par le code.
///
/// Branchement prévu au Lot 2 (`TableScoreApp`) :
/// ```
/// let repository = try PersistenceController.makeRepository(context: .current)
/// ```
/// En cas d'échec : afficher une erreur (`userFacingMessage`), jamais de `fatalError`.
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
        URL.applicationSupportDirectory.appending(path: storeFileName, directoryHint: .notDirectory)
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
            return try fileConfiguration(url: defaultStoreURL, schema: schema, allowsSave: allowsSave)
        case .file(let url):
            return try fileConfiguration(url: url, schema: schema, allowsSave: allowsSave)
        }
    }

    static func makeContainer(
        storage: PersistenceStorage,
        allowsSave: Bool = true
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
            throw GameRepositoryError.storageFailure(.setup, message: ErrorDiagnostics.summary(of: error))
        }
    }

    /// Dépôt de l'application selon le contexte de lancement (voir `storage(for:)`).
    @MainActor
    static func makeRepository(context: LaunchContext = .current) throws(GameRepositoryError) -> SwiftDataGameRepository {
        #if DEBUG
        try resetUITestStoreIfRequested(context: context)
        #endif
        let container = try makeContainer(storage: storage(for: context))
        return SwiftDataGameRepository(container: container)
    }

    private static func fileConfiguration(
        url: URL,
        schema: Schema,
        allowsSave: Bool
    ) throws(GameRepositoryError) -> ModelConfiguration {
        do {
            // `Application Support` n'existe pas encore lors d'une installation fraîche.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw GameRepositoryError.storageFailure(.setup, message: ErrorDiagnostics.summary(of: error))
        }
        return ModelConfiguration(
            "TableScore",
            schema: schema,
            url: url,
            allowsSave: allowsSave,
            cloudKitDatabase: .none
        )
    }
}
