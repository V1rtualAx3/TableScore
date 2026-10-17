// Placeholder T0 — remplacé par T5.
// Contrat figé : `GameOverSection(game: SavedGame, onReplay: @escaping () -> Void)`, intégrée
// par `GameView` (T3) quand `game.isOver`. Vainqueur(s), classement final : uniquement à partir
// de `game.computation` (`status`, `standingsAtEnd`, `totalsAtEnd`), jamais recalculés ici.
// « Rejouer » : `onReplay()` (la création est faite par le modèle de `GameView`).
// « Voir l'historique » / « Accueil » : `router.show(.history(game.id))` / `router.popToRoot()`.
// Identifiants : `AccessibilityID.GameOver.*`.
import SwiftUI

struct GameOverSection: View {
    let game: SavedGame
    let onReplay: () -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Text("Partie terminée")
                .font(.title.bold())
                .accessibilityIdentifier(AccessibilityID.GameOver.title)

            PrimaryActionButton("Rejouer avec les mêmes joueurs", action: onReplay)
                .accessibilityIdentifier(AccessibilityID.GameOver.replay)
        }
        .padding(Theme.Spacing.l)
    }
}
