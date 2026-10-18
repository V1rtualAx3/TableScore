import SwiftUI

/// Point d'entrée de l'application TableScore.
///
/// L'application fonctionne entièrement hors ligne : aucune requête réseau,
/// aucun compte, aucune télémétrie. Les données restent sur l'appareil.
@main
struct TableScoreApp: App {
    var body: some Scene {
        WindowGroup {
            HomeView()
        }
    }
}
