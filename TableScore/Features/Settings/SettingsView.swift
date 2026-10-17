// Placeholder T0 — remplacé par T7.
// Contrat figé : `SettingsView()` (sans paramètre), destination de `Route.settings`.
// Préférence haptique : `@AppStorage(AppPreferenceKey.hapticsEnabled)`.
// Identifiants : `AccessibilityID.Settings.*`.
import SwiftUI

struct SettingsView: View {
    var body: some View {
        ContentUnavailableView(
            "Paramètres",
            systemImage: "gearshape",
            description: Text("Écran en préparation.")
        )
        .navigationTitle("Paramètres")
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
}
#endif
