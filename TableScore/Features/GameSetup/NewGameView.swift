// Placeholder T0 — remplacé par T2.
// Contrat figé : `NewGameView()` (sans paramètre), présentée en feuille par `RootView`
// (`AppSheet.newGame`). Contient son propre `NavigationStack` interne.
// « Commencer » : `repository.createGame(...)` (la partie active éventuelle est close par le
// dépôt dans la même transaction), puis `router.notifyDataChanged()` et `router.openGame(id)`.
// Identifiants : `AccessibilityID.Setup.*`.
import SwiftUI

struct NewGameView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Nouvelle partie",
                systemImage: "person.2",
                description: Text("Écran en préparation.")
            )
            .navigationTitle("Nouvelle partie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        router.dismissSheet()
                    }
                    .accessibilityIdentifier(AccessibilityID.Setup.cancel)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    NewGameView()
        .previewEnvironment()
}
#endif
