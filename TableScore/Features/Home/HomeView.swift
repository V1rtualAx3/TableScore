// Placeholder T0 — remplacé par T1.
// Contrat figé : `HomeView()` (sans paramètre), racine de `RootView`. Ne crée PAS de
// `NavigationStack` (fourni par `RootView`). Titre de navigation « TableScore ».
// Dépendances lues dans l'environnement : `AppRouter`, `AppDependencies`.
// Identifiants : `AccessibilityID.Home.*` (`home.newGame` obligatoire, testé par LaunchTests).
import SwiftUI

struct HomeView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            Section {
                NavigationLink(value: Route.finishedGames) {
                    Label("Parties terminées", systemImage: "archivebox")
                }
                .accessibilityIdentifier(AccessibilityID.Home.finishedGames)

                NavigationLink(value: Route.rules) {
                    Label("Règles de comptage", systemImage: "book")
                }
                .accessibilityIdentifier(AccessibilityID.Home.rules)

                NavigationLink(value: Route.settings) {
                    Label("Paramètres", systemImage: "gearshape")
                }
                .accessibilityIdentifier(AccessibilityID.Home.settings)
            }
        }
        .navigationTitle("TableScore")
        .primaryActionInset {
            PrimaryActionButton("Nouvelle partie") {
                router.present(.newGame)
            }
            .accessibilityIdentifier(AccessibilityID.Home.newGame)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        HomeView()
    }
    .previewEnvironment()
}
#endif
