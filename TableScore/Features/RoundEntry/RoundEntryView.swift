// Placeholder T0 — remplacé par T4.
// Contrat figé : `RoundEntryView(gameID: UUID, mode: RoundEntryMode)`, présentée en feuille par
// `RootView` (`AppSheet.roundEntry`). Contient son propre `NavigationStack` interne.
// `.new` : `repository.appendRound` ; `.edit(roundID:)` : `repository.replaceRound` (décision
// explicite en cas de fin anticipée, §4.6). Après succès : `router.notifyDataChanged()` puis
// fermeture. Identifiants : `AccessibilityID.Round.*`.
import SwiftUI

struct RoundEntryView: View {
    let gameID: UUID
    let mode: RoundEntryMode

    @Environment(AppRouter.self) private var router

    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Manche",
                systemImage: "square.and.pencil",
                description: Text("Écran en préparation.")
            )
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") {
                        router.dismissSheet()
                    }
                    .accessibilityIdentifier(AccessibilityID.Round.cancel)
                }
            }
        }
    }
}

#if DEBUG
#Preview {
    RoundEntryView(gameID: UITestSeed.nearEnd.activeGameID, mode: .new)
        .previewEnvironment(.nearEnd)
}
#endif
