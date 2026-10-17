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
    /// Argument de lancement des tests UI : stockage en mémoire (builds Debug uniquement).
    static let uiTestingLaunchArgument = "-uiTesting"
    static let storeFileName = "TableScore.store"
    /// Variables d'environnement posées par XCTest dans l'app hôte des tests unitaires.
    static let hostedTestEnvironmentKeys = ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]

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

    /// Choix pur du stockage :
    /// - Release : **toujours** `applicationSupport` (aucun argument ne peut détourner le stockage
    ///   d'une app distribuée) ;
    /// - Debug + `-uiTesting` : mémoire (tests UI ; le futur `-seed` suivra la même règle) ;
    /// - Debug + app hôte de tests unitaires (variables XCTest) : mémoire, le vrai store n'est
    ///   jamais ouvert par les tests ;
    /// - sinon `applicationSupport`.
    static func storage(for context: LaunchContext) -> PersistenceStorage {
        guard context.isDebugBuild else { return .applicationSupport }
        if context.arguments.contains(uiTestingLaunchArgument) { return .inMemory }
        if hostedTestEnvironmentKeys.contains(where: { context.environment[$0] != nil }) { return .inMemory }
        return .applicationSupport
    }

    /// Emplacement du stockage persistant, dans le conteneur privé de l'application.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: storeFileName, directoryHint: .notDirectory)
    }

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
            throw GameRepositoryError.storageFailure(.setup, message: String(describing: type(of: error)))
        }
    }

    /// Dépôt de l'application selon le contexte de lancement (voir `storage(for:)`).
    @MainActor
    static func makeRepository(context: LaunchContext = .current) throws(GameRepositoryError) -> SwiftDataGameRepository {
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
            throw GameRepositoryError.storageFailure(.setup, message: String(describing: type(of: error)))
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
