import Accessibility
import SwiftUI

/// Paramètres minimaux (docs/ux/lot2-parcours.md §2.8) : haptique, suppression globale, à propos.
struct SettingsView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    @State private var model: SettingsModel?
    /// Présentation de l'alerte finale, découplée du modèle : elle n'apparaît qu'après la fermeture
    /// de la boîte de dialogue (deux présentations simultanées sont ignorées par SwiftUI).
    @State private var isLastConfirmationPresented = false

    var body: some View {
        Group {
            if let model {
                form(model)
            } else {
                Color.clear
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Paramètres")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model == nil {
                model = SettingsModel(repository: dependencies.repository)
            }
        }
    }

    private func form(_ model: SettingsModel) -> some View {
        Form {
            Section {
                Toggle("Retours haptiques", isOn: $hapticsEnabled)
                    .accessibilityIdentifier(AccessibilityID.Settings.haptics)
            } footer: {
                Text("Vibrations légères lors de l'enregistrement d'une manche et en fin de partie.")
            }

            Section {
                Button("Supprimer toutes les données", role: .destructive) {
                    model.beginDeletion()
                }
                .accessibilityIdentifier(AccessibilityID.Settings.deleteAllData)
                .frame(minHeight: Theme.Size.minTapTarget, alignment: .leading)
                .confirmationDialog(
                    "Supprimer toutes les données\u{202F}?",
                    isPresented: Binding(
                        get: { model.deletionStep == .first },
                        set: { isPresented in
                            // Fermeture sans choix (toucher à côté) : annulation. Si un bouton a déjà
                            // fait avancer l'étape, rien à faire.
                            if !isPresented && model.deletionStep == .first { model.cancelDeletion() }
                        }
                    ),
                    titleVisibility: .visible
                ) {
                    Button("Continuer", role: .destructive) { model.continueDeletion() }
                    Button("Annuler", role: .cancel) { model.cancelDeletion() }
                } message: {
                    Text("Toutes les parties, en cours, terminées ou interrompues, seront effacées de cet iPhone.")
                }
            } footer: {
                if model.didDeleteAll {
                    Label("Toutes les données ont été supprimées.", systemImage: "checkmark.circle")
                } else {
                    Text("Les parties sont supprimées définitivement, sans possibilité de les récupérer.")
                }
            }

            Section("Confidentialité") {
                Text(
                    "Vos données (prénoms saisis et scores) restent uniquement sur cet iPhone. "
                    + "L'application n'établit aucune connexion et ne collecte rien."
                )
                Text(
                    "Les sauvegardes de l'iPhone ou d'iCloud, gérées par le système et selon vos réglages, "
                    + "peuvent inclure ces données."
                )
                .foregroundStyle(.secondary)
            }

            Section("À propos") {
                LabeledContent("Version", value: SettingsModel.currentVersionText)
                Text("Fonctionne entièrement hors ligne.")
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: model.didDeleteAll) { _, deleted in
            if deleted {
                AccessibilityNotification.Announcement("Toutes les données ont été supprimées.").post()
            }
        }
        .onChange(of: model.deletionStep) { _, step in
            if step == .lastConfirmation {
                Task { @MainActor in
                    // Laisse la boîte de dialogue se refermer avant de présenter l'alerte.
                    try? await Task.sleep(for: .milliseconds(400))
                    if model.deletionStep == .lastConfirmation { isLastConfirmationPresented = true }
                }
            } else {
                isLastConfirmationPresented = false
            }
        }
        .alert(
            "Dernière confirmation",
            isPresented: Binding(
                get: { isLastConfirmationPresented },
                set: { isPresented in
                    isLastConfirmationPresented = isPresented
                    if !isPresented && model.deletionStep == .lastConfirmation { model.cancelDeletion() }
                }
            )
        ) {
            Button("Tout supprimer", role: .destructive) {
                if model.confirmDeleteAll() {
                    router.notifyDataChanged()
                }
            }
            Button("Annuler", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text("Cette action est irréversible. Toutes les parties seront définitivement supprimées de cet iPhone.")
        }
        .alert(
            "Suppression impossible",
            isPresented: Binding(get: { model.hasError }, set: { model.hasError = $0 })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

#if DEBUG
#Preview("Paramètres") {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
}

#Preview("Sombre, XXL") {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment(.withHistory)
    .preferredColorScheme(.dark)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
