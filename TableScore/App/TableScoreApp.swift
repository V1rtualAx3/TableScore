import SwiftUI

/// Point d'entrée de l'application TableScore.
///
/// L'application fonctionne entièrement hors ligne : aucune requête réseau,
/// aucun compte, aucune télémétrie. Les données restent sur l'appareil.
///
/// Le stockage local est ouvert de façon synchrone au lancement (`AppBootstrap`) ; en cas
/// d'échec, un écran d'erreur lisible remplace l'application (jamais de `fatalError`).
@main
struct TableScoreApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            switch bootstrap.state {
            case .ready(let dependencies):
                RootView()
                    .environment(dependencies)
            case .failed(let message):
                StorageErrorView(message: message) {
                    bootstrap.retry()
                }
            }
        }
    }
}
