// Placeholder T0 — remplacé par T6.
// Contrat figé : `HistoryView(gameID: UUID)`, destination de `Route.history(gameID)`.
// Correction : `router.present(.roundEntry(gameID: gameID, mode: .edit(roundID: id)))`.
// Recharge sur `.task(id: router.dataRevision)`. Identifiants : `AccessibilityID.History.*`.
import SwiftUI

struct HistoryView: View {
    let gameID: UUID

    var body: some View {
        ContentUnavailableView(
            "Historique",
            systemImage: "list.number",
            description: Text("Écran en préparation.")
        )
        .navigationTitle("Historique")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HistoryView(gameID: UITestSeed.withHistory.activeGameID)
    }
    .previewEnvironment(.withHistory)
}
#endif
