import Accessibility
import SwiftUI

/// Historique et correction (cahier §4.6, docs/ux/lot2-parcours.md §2.5).
///
/// Contrat : destination de `Route.history(gameID)` ; rechargement sur
/// `.task(id: router.reloadKey(for: gameID))` ; corriger une manche =
/// `router.present(.roundEntry(gameID:mode: .edit(roundID:)))` (formulaire et résolution d'une
/// fin anticipée lors d'une correction : `RoundEntryView`). Pas de CTA proéminent : l'action
/// principale est de toucher une manche.
struct HistoryView: View {
    let gameID: UUID

    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @State private var model: HistoryModel?

    var body: some View {
        Group {
            if let model {
                HistoryContent(model: model)
            } else {
                Color.clear
            }
        }
        .navigationTitle("Historique")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: router.reloadKey(for: gameID)) {
            let current = HistoryModel.resolve(model, gameID: gameID, repository: dependencies.repository)
            if model !== current {
                model = current
            }
            current.load()
        }
    }
}

/// Contenu une fois le modèle créé (le dépôt vient de l'environnement).
private struct HistoryContent: View {
    @Bindable var model: HistoryModel

    @Environment(AppRouter.self) private var router
    @State private var isConfirmingDeletion = false
    @State private var confirmingNotice: HistoryModel.InconsistencyNotice?
    /// Manche dont les grilles de cartes sont consultées (lecture seule).
    @State private var cardsRow: HistoryModel.RoundRow?

    var body: some View {
        content
            .sheet(item: $cardsRow) { row in
                HistoryCardsSheet(row: row)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let deletion = model.undoableDeletion {
                    UndoDeletionBanner(text: deletion.bannerText) {
                        undoDeletion()
                    }
                }
            }
            .confirmationDialog(
                model.deletionConfirmationTitle,
                isPresented: $isConfirmingDeletion,
                titleVisibility: .visible
            ) {
                Button(model.deletionConfirmationButtonTitle, role: .destructive) {
                    deleteLastRound()
                }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Les totaux reviendront à leur état précédent.")
            }
            .confirmationDialog(
                confirmingNotice?.confirmationTitle ?? "",
                isPresented: noticeBinding,
                titleVisibility: .visible,
                presenting: confirmingNotice
            ) { notice in
                Button(notice.confirmationButtonTitle, role: .destructive) {
                    resolveInconsistency(notice)
                }
                Button("Annuler", role: .cancel) {}
            } message: { notice in
                Text(verbatim: notice.confirmationMessage)
            }
            .alert("Action impossible", isPresented: errorBinding, presenting: model.actionError) { _ in
                Button("OK", role: .cancel) {}
            } message: { message in
                Text(verbatim: message)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let loadError = model.loadError {
            ContentUnavailableView {
                Label("Impossible de lire l'historique", systemImage: Theme.Symbol.warning)
            } description: {
                Text(verbatim: loadError)
            } actions: {
                Button {
                    model.load()
                } label: {
                    Text("Réessayer").onAccentForeground()
                }
                .buttonStyle(.borderedProminent)
            }
        } else if model.hasLoaded && model.rows.isEmpty {
            ContentUnavailableView(
                "Aucune manche",
                systemImage: "list.number",
                description: Text("Les manches enregistrées apparaîtront ici.")
            )
        } else {
            roundList
        }
    }

    private var roundList: some View {
        List {
            if let notice = model.inconsistency {
                Section {
                    InconsistencyNoticeView(
                        notice: notice,
                        canResolve: model.canResolveInconsistency
                    ) {
                        confirmingNotice = notice
                    }
                }
            }
            Section {
                ForEach(model.rows) { row in
                    roundRow(row)
                    if row.hasCardEntries {
                        cardsButton(row)
                    }
                    // Juste sous la manche concernée (la plus récente, en haut de liste).
                    if row.isLast && model.canDeleteLastRound {
                        deleteLastRoundButton
                    }
                }
            } header: {
                Text(verbatim: model.lifecycleNote
                    ?? "Touchez une manche pour la corriger. Les manches suivantes seront recalculées.")
                    .textCase(nil)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// Consultation des grilles d'une manche saisie (en partie) en mode « Cartes » : feuille en
    /// lecture seule, disponible aussi pour une partie interrompue. Ligne distincte de la manche
    /// (qui, elle, ouvre la correction).
    private func cardsButton(_ row: HistoryModel.RoundRow) -> some View {
        Button {
            cardsRow = row
        } label: {
            Label {
                Text(verbatim: row.cardsButtonTitle)
            } icon: {
                Image(systemName: "square.grid.3x3")
            }
        }
        .accessibilityHint(Text("Affiche les grilles en lecture seule."))
        .accessibilityIdentifier(AccessibilityID.History.viewCards(index: row.index))
    }

    private var deleteLastRoundButton: some View {
        Button(role: .destructive) {
            isConfirmingDeletion = true
        } label: {
            // Rouge système ≈ 3,6:1 en clair : rouge contrasté du thème (texte et symbole).
            Label("Supprimer la dernière manche", systemImage: "trash")
                .foregroundStyle(Theme.Palette.destructive)
        }
        .accessibilityIdentifier(AccessibilityID.History.deleteLastRound)
    }

    @ViewBuilder
    private func roundRow(_ row: HistoryModel.RoundRow) -> some View {
        if model.isEditable {
            Button {
                requestEdit(row.id)
            } label: {
                HistoryRoundCard(row: row, showsDisclosure: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
            .accessibilityHint(Text(hint))
            .accessibilityIdentifier(AccessibilityID.History.round(index: row.index))
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if row.isLast && model.canDeleteLastRound {
                    // Pas de rôle `.destructive` : il retirerait la ligne avant la confirmation.
                    Button {
                        isConfirmingDeletion = true
                    } label: {
                        Label("Supprimer", systemImage: "trash")
                    }
                    .tint(.red)
                }
            }
        } else {
            HistoryRoundCard(row: row, showsDisclosure: false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: row.accessibilityLabel))
                .accessibilityIdentifier(AccessibilityID.History.round(index: row.index))
        }
    }

    private var hint: LocalizedStringKey {
        model.lifecycle == .finished
            ? "Corrige cette manche. La partie reste terminée si le seuil est toujours atteint."
            : "Corrige cette manche."
    }

    // MARK: Liaisons

    private var noticeBinding: Binding<Bool> {
        Binding(
            get: { confirmingNotice != nil },
            set: { isPresented in
                if !isPresented { confirmingNotice = nil }
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.actionError != nil },
            set: { isPresented in
                if !isPresented { model.actionError = nil }
            }
        )
    }

    // MARK: Actions

    private func requestEdit(_ roundID: UUID) {
        switch model.requestEdit(roundID: roundID) {
        case .present(let id):
            presentEdit(id)
        case .unavailable:
            break
        }
    }

    private func presentEdit(_ roundID: UUID) {
        router.present(.roundEntry(gameID: model.gameID, mode: .edit(roundID: roundID)))
    }

    private func deleteLastRound() {
        guard let index = model.lastRound?.index else { return }
        if model.deleteLastRound() {
            router.notifyDataChanged()
            announce("Manche \(index) supprimée. Vous pouvez annuler.")
        }
    }

    private func undoDeletion() {
        guard let index = model.undoableDeletion?.index else { return }
        if model.undoDeletion() {
            router.notifyDataChanged()
            announce("Manche \(index) rétablie.")
        }
    }

    private func resolveInconsistency(_ notice: HistoryModel.InconsistencyNotice) {
        confirmingNotice = nil
        if model.deleteRoundsAfterEarlyEnd(confirmed: notice) {
            router.notifyDataChanged()
        }
    }

    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }
}

/// Bandeau d'incohérence §4.6 : explication + action destructive explicite (confirmée ensuite).
private struct InconsistencyNoticeView: View {
    let notice: HistoryModel.InconsistencyNotice
    let canResolve: Bool
    let onResolve: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Label {
                Text(verbatim: notice.title)
                    .font(.headline)
            } icon: {
                Image(systemName: Theme.Symbol.warning)
                    .foregroundStyle(Theme.Palette.warning)
            }
            Text(verbatim: notice.message)
                .font(Theme.Typography.detail)
                .fixedSize(horizontal: false, vertical: true)
            if canResolve {
                // Style explicite : seul le bouton est actif, pas toute la ligne de la liste.
                Button(role: .destructive, action: onResolve) {
                    Text(verbatim: notice.actionTitle)
                        .foregroundStyle(Theme.Palette.destructive)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .contain)
    }
}

/// Bandeau « Manche n supprimée — Annuler », visible jusqu'à la prochaine action.
private struct UndoDeletionBanner: View {
    let text: String
    let onUndo: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Spacing.m) {
                message
                Spacer(minLength: Theme.Spacing.s)
                undoButton
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                message
                undoButton
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var message: some View {
        Label {
            Text(verbatim: text)
        } icon: {
            Image(systemName: "trash")
        }
        .font(Theme.Typography.detail)
    }

    private var undoButton: some View {
        Button(action: onUndo) {
            Text("Annuler").onAccentForeground()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel("Annuler la suppression")
        .accessibilityIdentifier(AccessibilityID.History.undoDeletion)
    }
}

#if DEBUG
#Preview("Partie en cours, 4 manches") {
    NavigationStack {
        HistoryView(gameID: UITestSeed.withHistory.activeGameID)
    }
    .previewEnvironment(.withHistory)
}

#Preview("Partie terminée — sombre") {
    NavigationStack {
        HistoryView(gameID: UITestSeed.GameKey.historyFinished.id)
    }
    .previewEnvironment(.withHistory)
    .preferredColorScheme(.dark)
}

#Preview("8 joueurs — XXL") {
    NavigationStack {
        HistoryView(gameID: UITestSeed.eightPlayers.activeGameID)
    }
    .previewEnvironment(.eightPlayers)
    .dynamicTypeSize(.accessibility3)
}

#Preview("Manche saisie en cartes") {
    NavigationStack {
        HistoryView(gameID: UITestSeed.withCards.activeGameID)
    }
    .previewEnvironment(.withCards)
}

#Preview("Partie introuvable") {
    NavigationStack {
        HistoryView(gameID: UUID())
    }
    .previewEnvironment()
}
#endif
