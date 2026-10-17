import SwiftUI
import UIKit

/// Feuille « Ajouter une manche » / « Corriger une manche » (docs/ux/lot2-parcours.md §2.4, §2.5).
///
/// Contrat figé : `RoundEntryView(gameID:mode:)`, présentée par `RootView` (`AppSheet.roundEntry`),
/// avec son propre `NavigationStack`. `.new` : `appendRound` ; `.edit(roundID:)` : `replaceRound`
/// avec décision explicite en cas de fin anticipée (§4.6). Après succès :
/// `router.notifyDataChanged()` puis `router.dismissSheet()`.
struct RoundEntryView: View {
    let gameID: UUID
    let mode: RoundEntryMode

    @Environment(AppDependencies.self) private var dependencies
    @State private var model: RoundEntryModel?

    var body: some View {
        NavigationStack {
            if let model {
                RoundEntryForm(model: model)
            } else {
                ProgressView()
            }
        }
        .onAppear {
            // Créé une seule fois par présentation : l'identifiant de manche reste stable.
            if model == nil {
                model = RoundEntryModel(gameID: gameID, mode: mode, repository: dependencies.repository)
            }
        }
    }
}

private struct RoundEntryForm: View {
    let model: RoundEntryModel

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    @FocusState private var focusedField: UUID?
    @State private var isConfirmingCancel = false

    var body: some View {
        content
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // Glisser vers le bas ne doit pas perdre une saisie commencée, ni laisser rouverte une
            // partie terminée (cas d'échec d'écriture, normalement résorbé immédiatement).
            .interactiveDismissDisabled(model.isDirty || model.isSaving || model.needsLifecycleRestore)
            .confirmationDialog(
                model.isEditing ? "Abandonner la correction\u{202F}?" : "Abandonner la saisie\u{202F}?",
                isPresented: $isConfirmingCancel,
                titleVisibility: .visible
            ) {
                Button("Abandonner", role: .destructive) {
                    close()
                }
                Button("Continuer la saisie", role: .cancel) {}
            }
            .alert(
                "Enregistrement impossible",
                isPresented: saveErrorBinding,
                presenting: model.saveErrorMessage
            ) { _ in
                Button("Réessayer") {
                    // Après la fermeture de l'alerte ; même identifiant de manche.
                    let model = model
                    Task { _ = model.save() }
                }
                Button("OK", role: .cancel) {}
            } message: { message in
                Text("\(message) Votre saisie est conservée.")
            }
            .alert(
                model.pendingDecision?.title ?? "",
                isPresented: decisionBinding,
                presenting: model.pendingDecision
            ) { decision in
                Button(decision.confirmTitle, role: decision.isDestructive ? .destructive : nil) {
                    // Choix explicite : seule voie d'écriture d'une décision (§4.6).
                    let model = model
                    Task { _ = model.confirm(decision) }
                }
                Button(decision.cancelTitle, role: .cancel) {
                    model.dismissDecision()
                }
            } message: { decision in
                Text(decision.message)
            }
            // Seconde confirmation de la suppression des manches postérieures (§4.6), comme dans
            // l'historique ; « Annuler » revient à la saisie sans rien écrire.
            .confirmationDialog(
                model.pendingDeletionConfirmation?.finalConfirmationTitle ?? "",
                isPresented: deletionConfirmationBinding,
                titleVisibility: .visible,
                presenting: model.pendingDeletionConfirmation
            ) { earlyEnd in
                Button(earlyEnd.finalConfirmationButtonTitle, role: .destructive) {
                    let model = model
                    Task { _ = model.confirmLaterRoundsDeletion(earlyEnd) }
                }
                Button("Annuler", role: .cancel) {
                    model.cancelLaterRoundsDeletion()
                }
            } message: { earlyEnd in
                Text(earlyEnd.finalConfirmationMessage)
            }
            .sensoryFeedback(trigger: model.closerID) { _, newValue in
                hapticsEnabled && newValue != nil ? .selection : nil
            }
            .sensoryFeedback(trigger: model.pendingDecision) { _, newValue in
                hapticsEnabled && newValue != nil ? .warning : nil
            }
            .onChange(of: model.isCompleted) { _, isCompleted in
                if isCompleted { finish() }
            }
            .onDisappear {
                // Toute fermeture (y compris par glissement) : filet de sécurité du statut d'une
                // partie terminée rouverte pour enregistrer. Aucune écriture dans le cas normal.
                if model.restoreLifecycleIfNeeded() {
                    router.notifyDataChanged()
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .failed(let message):
            ContentUnavailableView {
                Label("Saisie impossible", systemImage: Theme.Symbol.warning)
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") {
                    model.retryLoad()
                }
                .buttonStyle(.bordered)
            }
        case .loaded:
            form
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    ForEach(model.fields) { field in
                        ScoreEntryRow(field: field, model: model, focus: $focusedField)
                    }
                } header: {
                    Text("Points de la manche")
                } footer: {
                    Text("Score de chaque joueur, colonnes déjà retirées. «\u{00A0}±\u{00A0}» rend un score négatif.")
                }

                CloserPicker(model: model)

                if let preview = model.preview {
                    RoundPreviewSection(preview: preview)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Suivant") {
                        focusNextField(proxy: proxy)
                    }
                    Spacer()
                    Button("OK") {
                        focusedField = nil
                    }
                }
            }
            // Barre d'action au-dessus du clavier (safe area clavier respectée).
            .primaryActionInset {
                actionSummary
                PrimaryActionButton(LocalizedStringKey(model.saveTitle), isLoading: model.isSaving) {
                    _ = model.save()
                }
                .disabled(!model.canSave)
                .accessibilityHint(model.blockingHint ?? "")
                .accessibilityIdentifier(AccessibilityID.Round.save)
            }
        }
        .task {
            // Ajout : le clavier s'ouvre directement sur le premier joueur.
            if !model.isEditing, focusedField == nil {
                focusedField = model.fields.first?.participantID
            }
        }
    }

    // MARK: Zone d'action

    /// Ligne courte au-dessus du bouton : pénalité du clôturant (saisie complète, visible avant
    /// d'enregistrer même clavier ouvert) ou ce qui manque encore. Tailles d'accessibilité : une
    /// seule ligne, et rien tant qu'un champ a le focus (le clavier occupe déjà l'écran ; le
    /// détail reste dans l'aperçu et dans l'indice VoiceOver du bouton).
    @ViewBuilder
    private var actionSummary: some View {
        let isAccessibilitySize = dynamicTypeSize.isAccessibilitySize
        if !(isAccessibilitySize && focusedField != nil) {
            if let line = model.closerPreviewLine, let description = line.closerDescription {
                Label {
                    Text(verbatim: description.text)
                } icon: {
                    Image(systemName: line.isDoubled ? Theme.Symbol.doubled : Theme.Symbol.closer)
                        .foregroundStyle(line.isDoubled ? Theme.Palette.doubled : Color.secondary)
                }
                .font(.footnote.weight(line.isDoubled ? .semibold : .regular))
                .lineLimit(isAccessibilitySize ? 1 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(description.spoken)
            } else if let summary = model.blockingSummary {
                Label {
                    Text(summary)
                } icon: {
                    Image(systemName: "info.circle")
                }
                .font(.footnote)
                .foregroundStyle(Color.secondary)
                // Hauteur bornée avec le clavier ouvert ; liste complète lue par VoiceOver.
                .lineLimit(isAccessibilitySize ? 1 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.blockingHint ?? summary)
                .accessibilityIdentifier(AccessibilityID.Round.blockingReasons)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Annuler") {
                if model.isDirty {
                    isConfirmingCancel = true
                } else {
                    close()
                }
            }
            .disabled(model.isSaving)
            .accessibilityIdentifier(AccessibilityID.Round.cancel)
        }
    }

    // MARK: Liaisons des alertes

    private var saveErrorBinding: Binding<Bool> {
        let model = model
        return Binding(
            get: { model.saveErrorMessage != nil },
            set: { isPresented in
                if !isPresented { model.dismissSaveError() }
            }
        )
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        let model = model
        return Binding(
            get: { model.pendingDeletionConfirmation != nil },
            set: { isPresented in
                // Fermeture sans choix : rien n'est écrit, la saisie est conservée.
                if !isPresented { model.cancelLaterRoundsDeletion() }
            }
        )
    }

    private var decisionBinding: Binding<Bool> {
        let model = model
        return Binding(
            get: { model.pendingDecision != nil },
            set: { isPresented in
                // Fermeture sans choix : rien n'est écrit, la saisie est conservée.
                if !isPresented { model.dismissDecision() }
            }
        )
    }

    // MARK: Actions

    /// Champ suivant ; après le dernier joueur, ferme le clavier et montre le choix du clôturant.
    private func focusNextField(proxy: ScrollViewProxy) {
        let fields = model.fields
        guard let current = focusedField,
              let position = fields.firstIndex(where: { $0.participantID == current }),
              position + 1 < fields.count
        else {
            focusedField = nil
            withAnimation(reduceMotion ? nil : .default) {
                proxy.scrollTo(CloserPicker.scrollAnchor, anchor: .top)
            }
            return
        }
        focusedField = fields[position + 1].participantID
    }

    private func finish() {
        // L'ajout d'une manche est déjà confirmé par l'écran de partie (bannière + haptique
        // `.success`) ; une correction n'a pas d'autre retour : haptique ici seulement.
        if model.isEditing && hapticsEnabled {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        _ = model.prepareForDismissal()
        router.notifyDataChanged()
        router.dismissSheet()
    }

    private func close() {
        if model.prepareForDismissal() {
            router.notifyDataChanged()
        }
        router.dismissSheet()
    }
}

#if DEBUG
#Preview("Ajout — 3 joueurs") {
    RoundEntryView(gameID: UITestSeed.nearEnd.activeGameID, mode: .new)
        .previewEnvironment(.nearEnd)
}

#Preview("Ajout — 8 joueurs, sombre") {
    RoundEntryView(gameID: UITestSeed.eightPlayers.activeGameID, mode: .new)
        .previewEnvironment(.eightPlayers)
        .preferredColorScheme(.dark)
}

#Preview("Ajout — 8 joueurs, Dynamic Type XXL") {
    RoundEntryView(gameID: UITestSeed.eightPlayers.activeGameID, mode: .new)
        .previewEnvironment(.eightPlayers)
        .dynamicTypeSize(.accessibility3)
}

#Preview("Correction de la manche 2") {
    RoundEntryView(
        gameID: UITestSeed.withHistory.activeGameID,
        mode: .edit(roundID: UITestSeed.GameKey.historyActive.roundID(index: 2))
    )
    .previewEnvironment(.withHistory)
}
#endif
