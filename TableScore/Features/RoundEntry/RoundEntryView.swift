import SwiftUI
import UIKit

/// Feuille « Ajouter une manche » / « Corriger une manche » (docs/ux/lot2-parcours.md §2.4, §2.5).
///
/// Contrat figé : `RoundEntryView(gameID:mode:)`, présentée par `RootView` (`AppSheet.roundEntry`),
/// avec son propre `NavigationStack`. `.new` : `appendRound` ; `.edit(roundID:)` : `replaceRound`
/// avec décision explicite en cas de fin anticipée (§4.6). Après succès :
/// `router.notifyDataChanged()` puis `router.dismissSheet()`.
///
/// Structure (temps de vérification de types borné) : `body` empile des étapes nommées, chacune
/// ajoutant un petit nombre de modificateurs ; boutons, titres et liaisons sont des membres
/// séparés au type explicite.
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

    /// Délai avant d'afficher la seconde confirmation : laisse l'alerte précédente finir de se
    /// fermer (animation système ≈ 0,3 s). Présenter pendant la fermeture peut être ignoré par
    /// SwiftUI ; si cela arrivait malgré tout, rien n'est bloqué (`save()` abandonne la décision
    /// en attente et la redemande).
    private static let deletionConfirmationDelay: Duration = .milliseconds(450)

    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(AppPreferenceKey.hapticsEnabled) private var hapticsEnabled = true
    @FocusState private var focusedField: UUID?
    @State private var isConfirmingCancel = false
    /// Seconde confirmation effectivement présentée (après la fermeture de l'alerte de décision).
    @State private var isShowingDeletionConfirmation = false

    var body: some View {
        withLifecycleObservers
    }

    // MARK: Étapes de composition

    private var withNavigation: some View {
        content
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            // Glisser vers le bas ne doit pas perdre une saisie commencée, ni laisser rouverte une
            // partie terminée (cas d'échec d'écriture, normalement résorbé immédiatement).
            .interactiveDismissDisabled(isInteractiveDismissDisabled)
    }

    private var withCancelConfirmation: some View {
        withNavigation
            .confirmationDialog(cancelDialogTitle, isPresented: $isConfirmingCancel, titleVisibility: .visible) {
                cancelDialogActions
            }
    }

    private var withSaveErrorAlert: some View {
        withCancelConfirmation
            .alert(
                "Enregistrement impossible",
                isPresented: saveErrorBinding,
                presenting: model.saveErrorMessage,
                actions: saveErrorActions,
                message: saveErrorMessage
            )
    }

    private var withDecisionAlert: some View {
        withSaveErrorAlert
            .alert(
                decisionTitle,
                isPresented: decisionBinding,
                presenting: model.pendingDecision,
                actions: decisionActions,
                message: decisionMessage
            )
    }

    /// Seconde confirmation de la suppression des manches postérieures (§4.6), comme dans
    /// l'historique ; « Annuler » revient à la saisie sans rien écrire.
    private var withDeletionConfirmation: some View {
        withDecisionAlert
            .confirmationDialog(
                deletionConfirmationTitle,
                isPresented: deletionConfirmationBinding,
                titleVisibility: .visible,
                presenting: model.pendingDeletionConfirmation,
                actions: deletionConfirmationActions,
                message: deletionConfirmationMessage
            )
    }

    private var withFeedback: some View {
        withDeletionConfirmation
            .sensoryFeedback(trigger: model.closerID, selectionFeedback)
            .sensoryFeedback(trigger: model.pendingDecision, decisionFeedback)
    }

    private var withLifecycleObservers: some View {
        withFeedback
            .onChange(of: model.isCompleted) { _, isCompleted in
                if isCompleted { finish() }
            }
            .onChange(of: model.pendingDeletionConfirmation) { _, pending in
                deletionConfirmationDidChange(pending)
            }
            .onDisappear(perform: restoreLifecycleOnDisappear)
    }

    // MARK: Contenu

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .failed(let message):
            loadFailure(message)
        case .loaded:
            form
        }
    }

    private func loadFailure(_ message: String) -> some View {
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
    }

    private var form: some View {
        ScrollViewReader { proxy in
            formSections
                .scrollDismissesKeyboard(.interactively)
                .toolbar {
                    keyboardToolbar(proxy: proxy)
                }
                // Barre d'action au-dessus du clavier (safe area clavier respectée).
                .primaryActionInset {
                    actionSummary
                    saveButton
                }
        }
        .task {
            // Ajout : le clavier s'ouvre directement sur le premier joueur.
            if !model.isEditing, focusedField == nil {
                focusedField = model.fields.first?.participantID
            }
        }
    }

    private var formSections: some View {
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
    }

    @ToolbarContentBuilder
    private func keyboardToolbar(proxy: ScrollViewProxy) -> some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Button("Suivant") {
                focusNextField(proxy: proxy)
            }
            .accessibilityIdentifier(AccessibilityID.Round.keyboardNext)
            Spacer()
            Button("OK") {
                focusedField = nil
            }
            .accessibilityIdentifier(AccessibilityID.Round.keyboardDone)
        }
    }

    private var saveButton: some View {
        PrimaryActionButton(LocalizedStringKey(model.saveTitle), isLoading: model.isSaving) {
            _ = model.save()
        }
        .disabled(!model.canSave)
        .accessibilityHint(Text(verbatim: model.blockingHint ?? ""))
        .accessibilityIdentifier(AccessibilityID.Round.save)
    }

    // MARK: Zone d'action

    /// Ligne courte au-dessus du bouton : pénalité du clôturant (saisie complète, visible avant
    /// d'enregistrer même clavier ouvert) ou ce qui manque encore. Tailles d'accessibilité : une
    /// seule ligne, et rien tant qu'un champ a le focus (le clavier occupe déjà l'écran ; le
    /// détail reste dans l'aperçu et dans l'indice VoiceOver du bouton).
    @ViewBuilder
    private var actionSummary: some View {
        if showsActionSummary {
            if let line = model.closerPreviewLine, let description = line.closerDescription {
                CloserPreviewLabel(
                    description: description,
                    isDoubled: line.isDoubled,
                    lineLimit: summaryLineLimit(regular: 2)
                )
            } else if let summary = model.blockingSummary {
                BlockingSummaryLabel(
                    summary: summary,
                    spokenSummary: model.blockingHint ?? summary,
                    lineLimit: summaryLineLimit(regular: 3)
                )
            }
        }
    }

    private var showsActionSummary: Bool {
        !(dynamicTypeSize.isAccessibilitySize && focusedField != nil)
    }

    private func summaryLineLimit(regular: Int) -> Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : regular
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Annuler", action: cancelTapped)
                .disabled(model.isSaving)
                .accessibilityIdentifier(AccessibilityID.Round.cancel)
        }
    }

    // MARK: Titres et contenus des alertes

    private var isInteractiveDismissDisabled: Bool {
        model.isDirty || model.isSaving || model.needsLifecycleRestore
    }

    private var cancelDialogTitle: String {
        if model.isEditing {
            return "Abandonner la correction\u{202F}?"
        }
        return "Abandonner la saisie\u{202F}?"
    }

    @ViewBuilder
    private var cancelDialogActions: some View {
        Button("Abandonner", role: .destructive, action: close)
        Button("Continuer la saisie", role: .cancel) {}
    }

    @ViewBuilder
    private func saveErrorActions(_ message: String) -> some View {
        Button("Réessayer", action: retrySave)
        Button("OK", role: .cancel) {}
    }

    private func saveErrorMessage(_ message: String) -> Text {
        Text(verbatim: "\(message) Votre saisie est conservée.")
    }

    private var decisionTitle: String {
        model.pendingDecision?.title ?? ""
    }

    @ViewBuilder
    private func decisionActions(_ decision: RoundEntryModel.Decision) -> some View {
        let role: ButtonRole? = decision.isDestructive ? .destructive : nil
        Button(decision.confirmTitle, role: role) {
            confirm(decision)
        }
        Button(decision.cancelTitle, role: .cancel) {
            model.dismissDecision()
        }
    }

    private func decisionMessage(_ decision: RoundEntryModel.Decision) -> Text {
        Text(verbatim: decision.message)
    }

    private var deletionConfirmationTitle: String {
        model.pendingDeletionConfirmation?.finalConfirmationTitle ?? ""
    }

    @ViewBuilder
    private func deletionConfirmationActions(_ earlyEnd: RoundEntryModel.EarlyEndDecision) -> some View {
        Button(earlyEnd.finalConfirmationButtonTitle, role: .destructive) {
            confirmDeletion(earlyEnd)
        }
        Button("Annuler", role: .cancel) {
            cancelDeletion()
        }
    }

    private func deletionConfirmationMessage(_ earlyEnd: RoundEntryModel.EarlyEndDecision) -> Text {
        Text(verbatim: earlyEnd.finalConfirmationMessage)
    }

    private func selectionFeedback(_ oldValue: UUID?, _ newValue: UUID?) -> SensoryFeedback? {
        guard hapticsEnabled, newValue != nil else { return nil }
        return .selection
    }

    private func decisionFeedback(
        _ oldValue: RoundEntryModel.Decision?,
        _ newValue: RoundEntryModel.Decision?
    ) -> SensoryFeedback? {
        guard hapticsEnabled, newValue != nil else { return nil }
        return .warning
    }

    // MARK: Liaisons des alertes

    private var saveErrorBinding: Binding<Bool> {
        let model = model
        return Binding<Bool>(
            get: { model.saveErrorMessage != nil },
            set: { (isPresented: Bool) in
                if !isPresented { model.dismissSaveError() }
            }
        )
    }

    /// Fermeture sans choix : rien n'est écrit, la saisie est conservée. Le setter ne touche que
    /// `pendingDecision` : l'action du bouton reçoit la décision en paramètre, quel que soit
    /// l'ordre d'exécution choisi par SwiftUI.
    private var decisionBinding: Binding<Bool> {
        let model = model
        return Binding<Bool>(
            get: { model.pendingDecision != nil },
            set: { (isPresented: Bool) in
                if !isPresented { model.dismissDecision() }
            }
        )
    }

    /// Présentée seulement après le délai de fermeture de l'alerte (état local). Le setter ne fait
    /// que masquer la boîte : l'abandon de l'étape est fait par le bouton « Annuler », et une
    /// fermeture sans bouton laisse une étape inerte que le prochain `save()` abandonne.
    private var deletionConfirmationBinding: Binding<Bool> {
        let model = model
        let isShowing = $isShowingDeletionConfirmation
        return Binding<Bool>(
            get: { isShowing.wrappedValue && model.pendingDeletionConfirmation != nil },
            set: { (isPresented: Bool) in
                if !isPresented { isShowing.wrappedValue = false }
            }
        )
    }

    // MARK: Actions

    private func cancelTapped() {
        if model.isDirty {
            isConfirmingCancel = true
        } else {
            close()
        }
    }

    private func retrySave() {
        // Après la fermeture de l'alerte ; même identifiant de manche.
        let model = model
        Task { _ = model.save() }
    }

    /// Choix explicite : seule voie d'écriture d'une décision (§4.6). Exécuté après la fermeture
    /// de l'alerte ; `.deleteLaterRounds` n'écrit rien et demande la seconde confirmation.
    private func confirm(_ decision: RoundEntryModel.Decision) {
        let model = model
        Task { _ = model.confirm(decision) }
    }

    private func confirmDeletion(_ earlyEnd: RoundEntryModel.EarlyEndDecision) {
        isShowingDeletionConfirmation = false
        let model = model
        Task { _ = model.confirmLaterRoundsDeletion(earlyEnd) }
    }

    private func cancelDeletion() {
        isShowingDeletionConfirmation = false
        model.cancelLaterRoundsDeletion()
    }

    /// Une seconde confirmation est demandée : présentation différée après la fermeture effective
    /// de l'alerte de décision. Étape abandonnée entre-temps ⇒ rien n'est présenté.
    private func deletionConfirmationDidChange(_ pending: RoundEntryModel.EarlyEndDecision?) {
        guard let pending else {
            isShowingDeletionConfirmation = false
            return
        }
        let model = model
        Task {
            try? await Task.sleep(for: Self.deletionConfirmationDelay)
            guard model.pendingDeletionConfirmation == pending, model.pendingDecision == nil else { return }
            isShowingDeletionConfirmation = true
        }
    }

    private func restoreLifecycleOnDisappear() {
        // Toute fermeture (y compris par glissement) : filet de sécurité du statut d'une partie
        // terminée rouverte pour enregistrer. Aucune écriture dans le cas normal.
        if model.restoreLifecycleIfNeeded() {
            router.notifyDataChanged()
        }
    }

    /// Champ suivant ; après le dernier joueur, ferme le clavier et montre le choix du clôturant.
    private func focusNextField(proxy: ScrollViewProxy) {
        let fields = model.fields
        guard let current = focusedField,
              let position = fields.firstIndex(where: { $0.participantID == current }),
              position + 1 < fields.count
        else {
            focusedField = nil
            let animation: Animation? = reduceMotion ? nil : .default
            withAnimation(animation) {
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

/// Pénalité du clôturant au-dessus du bouton : « Alice : 10 → 20 (score doublé : égalité avec Chloé) ».
private struct CloserPreviewLabel: View {
    let description: PenaltyPreviewFormatter.Description
    let isDoubled: Bool
    let lineLimit: Int

    var body: some View {
        Label {
            Text(verbatim: description.text)
        } icon: {
            icon
        }
        .font(font)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: description.spoken))
    }

    @ViewBuilder
    private var icon: some View {
        if isDoubled {
            Image(systemName: Theme.Symbol.doubled)
                .foregroundStyle(Theme.Palette.doubled)
        } else {
            Image(systemName: Theme.Symbol.closer)
                .foregroundStyle(Color.secondary)
        }
    }

    private var font: Font {
        isDoubled ? Font.footnote.weight(.semibold) : Font.footnote
    }
}

/// Ce qui manque encore (hauteur bornée avec le clavier ouvert ; liste complète lue par VoiceOver).
private struct BlockingSummaryLabel: View {
    let summary: String
    let spokenSummary: String
    let lineLimit: Int

    var body: some View {
        Label {
            Text(verbatim: summary)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(Color.secondary)
        .lineLimit(lineLimit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spokenSummary))
        .accessibilityIdentifier(AccessibilityID.Round.blockingReasons)
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
