// Placeholder T0 — remplacé par T7.
// Contrat figé : `RulesView()` (sans paramètre), destination de `Route.rules`. Contenu statique.
import SwiftUI

struct RulesView: View {
    var body: some View {
        ContentUnavailableView(
            "Règles de comptage",
            systemImage: "book",
            description: Text("Écran en préparation.")
        )
        .navigationTitle("Règles de comptage")
    }
}

#Preview {
    NavigationStack {
        RulesView()
    }
}
