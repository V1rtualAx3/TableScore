import SwiftUI
// Le moteur de score pur (ScoreEngine) vit dans le package local TableScoreKit.
// L'import valide dès le Lot 0 la liaison app ↔ package ; son API sera
// utilisée par la couche de présentation à partir du Lot 2.
import TableScoreKit

/// Écran d'accueil provisoire (Lot 0).
///
/// L'action principale « Nouvelle partie » est placée en bas, à portée de pouce,
/// et reste désactivée tant que le parcours de création n'est pas livré.
struct HomeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "list.number")
                        .font(.system(size: 56))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    Text("Compteur de points")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text("Notez les scores de vos parties autour de la table, sans connexion.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 48)
            }
            .navigationTitle("TableScore")
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Button {
                        // Création de partie : prévue au Lot 2.
                    } label: {
                        Text("Nouvelle partie")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(true)
                    .accessibilityHint("Bientôt disponible.")
                    .accessibilityIdentifier("home.newGameButton")

                    Text("Bientôt disponible")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.background)
            }
        }
    }
}

#Preview {
    HomeView()
}
