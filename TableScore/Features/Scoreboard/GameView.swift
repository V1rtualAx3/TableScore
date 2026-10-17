// Placeholder T0 — remplacé par T3.
// Contrat figé : `GameView(gameID: UUID)`, destination de `Route.game(gameID)`.
// Recharge la partie sur `.task(id: router.dataRevision)` ; « Ajouter une manche » :
// `router.present(.roundEntry(gameID: gameID, mode: .new))`. Si le moteur considère la partie
// terminée, affiche `GameOverSection(game:onReplay:)` (T5) à la place du CTA.
// Identifiants : `AccessibilityID.Game.*`.
import SwiftUI

struct GameView: View {
    let gameID: UUID

    @Environment(AppRouter.self) private var router

    var body: some View {
        ContentUnavailableView(
            "Partie en cours",
            systemImage: "list.number",
            description: Text("Écran en préparation.")
        )
        .navigationTitle("Partie")
        .primaryActionInset {
            PrimaryActionButton("Ajouter une manche") {
                router.present(.roundEntry(gameID: gameID, mode: .new))
            }
            .accessibilityIdentifier(AccessibilityID.Game.addRound)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        GameView(gameID: UITestSeed.nearEnd.activeGameID)
    }
    .previewEnvironment(.nearEnd)
}
#endif
