import Foundation
import Observation

/// Ouverture du stockage local au lancement, sans écran d'attente artificiel ni `fatalError`.
///
/// En cas d'échec, l'interface affiche `GameRepositoryError.userFacingMessage` (jamais le
/// diagnostic technique) et propose de réessayer.
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
