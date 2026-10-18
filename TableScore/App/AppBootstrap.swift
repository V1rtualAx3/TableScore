import Foundation
import Observation
import UIKit

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

    /// Dernière erreur d'ouverture (`nil` si prête). Exposée en statique pour `StorageErrorView`,
    /// qui ne reçoit que le message : elle décide seule d'offrir la mise de côté.
    private(set) static var lastLaunchFailure: GameRepositoryError?

    init(context: PersistenceController.LaunchContext = .current) {
        self.context = context
        self.state = Self.load(context: context)
        // Appareil pas encore déverrouillé depuis le démarrage : fichiers protégés illisibles.
        // Nouvel essai automatique dès qu'ils deviennent accessibles.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // File principale : déjà sur l'acteur principal.
            MainActor.assumeIsolated { self?.retryIfFailed() }
        }
    }

    func retry() {
        state = Self.load(context: context)
    }

    private func retryIfFailed() {
        if case .failed = state { retry() }
    }

    // MARK: Store illisible

    /// Vrai si le stockage du lancement est un fichier (la mise de côté n'a pas de sens en mémoire).
    static func canSetAsideUnreadableData(context: PersistenceController.LaunchContext) -> Bool {
        PersistenceController.storeLocation(for: PersistenceController.storage(for: context)) != nil
    }

    /// Décision pure : la mise de côté n'est proposée que pour un store fichier **réellement
    /// illisible** (échec d'ouverture du `ModelContainer`, `.openStore`), et jamais tant que les
    /// données protégées sont inaccessibles (appareil pas encore déverrouillé : l'échec ne prouve
    /// rien). Exclus : conflit ou échec de migration, effacement interrompu, disque (`.setup`).
    static func offersSetAside(
        after failure: GameRepositoryError?,
        context: PersistenceController.LaunchContext,
        protectedDataAvailable: Bool
    ) -> Bool {
        guard protectedDataAvailable, canSetAsideUnreadableData(context: context),
              case .storageFailure(.openStore, _) = failure else { return false }
        return true
    }

    /// Décision pour l'écran d'erreur courant.
    static func offersSetAsideNow(context: PersistenceController.LaunchContext) -> Bool {
        offersSetAside(
            after: lastLaunchFailure,
            context: context,
            protectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
        )
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
            lastLaunchFailure = nil
            return .ready(AppDependencies(repository: repository))
        } catch {
            // `from` accepte `any Error` : indépendant de l'inférence du type d'erreur typée.
            let repositoryError = GameRepositoryError.from(error, operation: .setup)
            lastLaunchFailure = repositoryError
            return .failed(message: repositoryError.userFacingMessage)
        }
    }
}
