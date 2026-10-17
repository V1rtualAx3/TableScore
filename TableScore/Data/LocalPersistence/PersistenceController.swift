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
enum PersistenceController {
    /// Argument de lancement des tests UI : stockage en mémoire, aucun accès disque persistant.
    static let uiTestingLaunchArgument = "-uiTesting"
    static let storeFileName = "TableScore.store"

    static func storage(forLaunchArguments arguments: [String]) -> PersistenceStorage {
        arguments.contains(uiTestingLaunchArgument) ? .inMemory : .applicationSupport
    }

    /// Emplacement du stockage persistant, dans le conteneur privé de l'application.
    static var defaultStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: storeFileName, directoryHint: .notDirectory)
    }

    static func makeContainer(storage: PersistenceStorage) throws(GameRepositoryError) -> ModelContainer {
        let schema = Schema(versionedSchema: TableScoreSchemaV1.self)
        let configuration: ModelConfiguration
        switch storage {
        case .inMemory:
            // Nom unique : chaque conteneur en mémoire est isolé des autres.
            configuration = ModelConfiguration(
                "TableScore-\(UUID().uuidString)",
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        case .applicationSupport:
            configuration = try fileConfiguration(url: defaultStoreURL, schema: schema)
        case .file(let url):
            configuration = try fileConfiguration(url: url, schema: schema)
        }
        do {
            return try ModelContainer(
                for: schema,
                migrationPlan: TableScoreMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            throw GameRepositoryError.storageFailure(.setup, message: String(describing: error))
        }
    }

    /// Dépôt de l'application selon les arguments de lancement (`-uiTesting` ⇒ mémoire).
    /// En cas d'échec, l'interface doit afficher une erreur (jamais de `fatalError`).
    @MainActor
    static func makeRepository(
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) throws(GameRepositoryError) -> SwiftDataGameRepository {
        let container = try makeContainer(storage: storage(forLaunchArguments: launchArguments))
        return SwiftDataGameRepository(container: container)
    }

    private static func fileConfiguration(url: URL, schema: Schema) throws(GameRepositoryError) -> ModelConfiguration {
        do {
            // `Application Support` n'existe pas encore lors d'une installation fraîche.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw GameRepositoryError.storageFailure(.setup, message: String(describing: error))
        }
        return ModelConfiguration(
            "TableScore",
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
    }
}
