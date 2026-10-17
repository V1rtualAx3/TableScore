// Placeholder T0 — remplacé par T7.
// Contrat figé : `FinishedGamesView()` (sans paramètre), destination de `Route.finishedGames`.
// Ouverture d'une partie en lecture : `router.show(.game(id))`.
// Identifiants : `AccessibilityID.FinishedGames.*`.
import SwiftUI

struct FinishedGamesView: View {
    var body: some View {
        ContentUnavailableView(
            "Aucune partie terminée",
            systemImage: "archivebox",
            description: Text("Écran en préparation.")
        )
        .navigationTitle("Parties terminées")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        FinishedGamesView()
    }
    .previewEnvironment(.withHistory)
}
#endif
