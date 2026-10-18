import Foundation
import Observation

/// Ouverture du stockage local au lancement, sans écran d'attente artificiel ni `fatalError`.
///
/// En cas d'échec, l'interface affiche `GameRepositoryError.userFacingMessage` (jamais le
/// diagnostic technique) et propose de réessayer ou, sur décision explicite et confirmée, de
/// mettre de côté les fichiers illisibles pour repartir d'un stockage vide (`StorageErrorView`).
@Observable
@MainActor
final class AppBootstrap {
    enum LaunchState {
        case ready(AppDependencies)
        case failed(message: String)
    }

    private(set) var state: LaunchState
    private let context: PersistenceController.LaunchContext

    init(context: PersistenceController.LaunchContext = .current) {
        self.context = context
        self.state = Self.load(context: context)
    }

    func retry() {
        state = Self.load(context: context)
    }

    // MARK: Store illisible

    /// Vrai si le stockage du lancement est un fichier (la mise de côté n'a pas de sens en mémoire).
    static func canSetAsideUnreadableData(context: PersistenceController.LaunchContext) -> Bool {
        PersistenceController.storeLocation(for: PersistenceController.storage(for: context)) != nil
    }

    /// Renomme les fichiers du store en `TableScore-illisible-<horodatage>.store(-wal/-shm)` dans
    /// le même dossier, **sans rien supprimer** ; l'appelant relance ensuite `retry()`, qui crée
    /// un store vide. Tout ou rien : en cas d'échec, aucun fichier n'est renommé ni supprimé.
    /// À n'appeler qu'après confirmation explicite de la personne.
    static func setAsideUnreadableData(
        context: PersistenceController.LaunchContext,
        fileSystem: any StoreFileSystem = LocalStoreFileSystem(),
        date: Date = Date()
    ) throws(GameRepositoryError) {
        try PersistenceController.setAsideUnreadableStore(
            storage: PersistenceController.storage(for: context),
            fileSystem: fileSystem,
            date: date
        )
    }

    private static func load(context: PersistenceController.LaunchContext) -> LaunchState {
        do {
            let repository = try PersistenceController.makeRepository(context: context)
            #if DEBUG
            // Fixtures de tests UI : stockage en mémoire uniquement (voir `UITestSeed`).
            try UITestSeed.applyIfRequested(context: context, to: repository)
            #endif
            return .ready(AppDependencies(repository: repository))
        } catch {
            // `from` accepte `any Error` : indépendant de l'inférence du type d'erreur typée.
            let repositoryError = GameRepositoryError.from(error, operation: .setup)
            return .failed(message: repositoryError.userFacingMessage)
        }
    }
}
