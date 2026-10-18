import Accessibility
import SwiftUI

/// Paramètres minimaux (docs/ux/lot2-parcours.md §2.8) : haptique, suppression globale, à propos.
struct SettingsView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    @State private var model: SettingsModel?
    /// Présentations découplées du modèle. Les setters de ces liaisons ne font que masquer :
    /// l'étape du modèle n'est modifiée que par les boutons (« Continuer », « Tout supprimer »,
    /// « Annuler »), quel que soit l'ordre setter / action choisi par SwiftUI. Une fermeture sans
    /// bouton laisse une étape inerte : rien n'est supprimé sans les deux boutons explicites, et
    /// `beginDeletion()` repart de zéro.
    @State private var isFirstConfirmationPresented = false
    /// L'alerte finale n'apparaît qu'après la fermeture de la boîte de dialogue (deux
    /// présentations simultanées sont ignorées par SwiftUI).
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
                    .foregroundStyle(Theme.Palette.secondaryText)
            }

            Section {
                Button(role: .destructive) {
                    model.beginDeletion()
                    isFirstConfirmationPresented = true
                } label: {
                    // Rouge système ≈ 3,6:1 en clair : rouge contrasté du thème.
                    Text("Supprimer toutes les données")
                        .foregroundStyle(Theme.Palette.destructive)
                }
                .accessibilityIdentifier(AccessibilityID.Settings.deleteAllData)
                .frame(minHeight: Theme.Size.minTapTarget, alignment: .leading)
                .confirmationDialog(
                    "Supprimer toutes les données\u{202F}?",
                    isPresented: $isFirstConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("Continuer", role: .destructive) { model.continueDeletion() }
                    Button("Annuler", role: .cancel) { model.cancelDeletion() }
                } message: {
                    Text("Toutes les parties, en cours, terminées ou interrompues, seront supprimées de cet iPhone.")
                }
            } footer: {
                Group {
                    if model.didDeleteAll {
                        Label("Toutes les parties ont été supprimées de cet iPhone.", systemImage: "checkmark.circle")
                    } else {
                        Text(
                            "Toutes les parties sont supprimées de cet iPhone. Les sauvegardes iCloud ou "
                            + "de l'ordinateur faites auparavant peuvent encore les contenir."
                        )
                    }
                }
                .foregroundStyle(Theme.Palette.secondaryText)
            }

            Section {
                Text(
                    "Vos données (prénoms saisis et scores) restent uniquement sur cet iPhone. "
                    + "L'application n'établit aucune connexion et ne collecte rien."
                )
                Text(
                    "Les sauvegardes de l'iPhone ou d'iCloud, gérées par le système et selon vos réglages, "
                    + "peuvent inclure ces données."
                )
                .foregroundStyle(Theme.Palette.secondaryText)
            } header: {
                Text("Confidentialité")
                    .foregroundStyle(Theme.Palette.secondaryText)
            }

            Section {
                LabeledContent("Version") {
                    Text(verbatim: SettingsModel.currentVersionText)
                        .foregroundStyle(Theme.Palette.secondaryText)
                }
                Text("Fonctionne entièrement hors ligne.")
                    .foregroundStyle(Theme.Palette.secondaryText)
            } header: {
                Text("À propos")
                    .foregroundStyle(Theme.Palette.secondaryText)
            }
        }
        .onChange(of: model.didDeleteAll) { _, deleted in
            if deleted {
                AccessibilityNotification.Announcement("Toutes les parties ont été supprimées de cet iPhone.").post()
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
            isPresented: $isLastConfirmationPresented
        ) {
            Button("Tout supprimer", role: .destructive) {
                // Vrai aussi si les parties sont supprimées mais l'effacement des fichiers inachevé
                // (message d'erreur affiché) : les écrans doivent se rafraîchir.
                if model.confirmDeleteAll() {
                    router.notifyDataChanged()
                }
            }
            Button("Annuler", role: .cancel) { model.cancelDeletion() }
        } message: {
            Text(
                "Cette action est irréversible. Toutes les parties seront supprimées de cet iPhone. "
                + "Les sauvegardes iCloud ou de l'ordinateur faites auparavant peuvent encore les contenir."
            )
        }
        .alert(
            "Suppression impossible",
            isPresented: Binding<Bool>(
                get: { model.hasError },
                set: { (isPresented: Bool) in model.hasError = isPresented }
            )
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
