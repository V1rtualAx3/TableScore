import SwiftUI

/// Parties terminées ou interrompues (docs/ux/lot2-parcours.md §2.6). Toucher une partie ouvre son
/// historique en lecture ; la suppression définitive est toujours confirmée.
struct FinishedGamesView: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(AppRouter.self) private var router
    @State private var model: FinishedGamesModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                Color.clear
            }
        }
        .background(Theme.Palette.background)
        .navigationTitle("Parties terminées")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: router.dataRevision) {
            let model = self.model ?? FinishedGamesModel(repository: dependencies.repository)
            self.model = model
            model.load()
        }
    }

    @ViewBuilder
    private func content(_ model: FinishedGamesModel) -> some View {
        if let message = model.loadErrorMessage {
            ContentUnavailableView {
                Label("Impossible de lire les parties enregistrées", systemImage: Theme.Symbol.warning)
            } description: {
                Text(message)
            } actions: {
                Button("Réessayer") { model.load() }
                    .buttonStyle(.borderedProminent)
            }
        } else if model.isLoaded && model.rows.isEmpty {
            ContentUnavailableView(
                "Aucune partie terminée",
                systemImage: "archivebox",
                description: Text("Les parties terminées ou interrompues apparaîtront ici.")
            )
        } else {
            list(model)
        }
    }

    private func list(_ model: FinishedGamesModel) -> some View {
        List {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { position, row in
                rowView(row, position: position, model: model)
            }
        }
        .confirmationDialog(
            "Supprimer définitivement cette partie\u{202F}?",
            isPresented: Binding(
                get: { model.pendingDeletionID != nil },
                set: { isPresented in if !isPresented { model.cancelDeletion() } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingDeletionID
        ) { id in
            Button("Supprimer définitivement", role: .destructive) {
                if model.delete(id: id) {
                    router.notifyDataChanged()
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: { _ in
            Text("Cette action est irréversible.")
        }
        .alert(
            "Suppression impossible",
            isPresented: Binding(get: { model.hasDeletionError }, set: { model.hasDeletionError = $0 })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.deletionErrorMessage ?? "")
        }
    }

    @ViewBuilder
    private func rowView(_ row: FinishedGameRow, position: Int, model: FinishedGamesModel) -> some View {
        Group {
            if row.isReadable {
                Button {
                    router.show(.history(row.id))
                } label: {
                    FinishedGameRowContent(row: row)
                }
                .buttonStyle(.plain)
            } else {
                FinishedGameRowContent(row: row)
            }
        }
        .accessibilityIdentifier(AccessibilityID.FinishedGames.game(position: position))
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Pas de `role: .destructive` : la ligne ne disparaît pas avant la confirmation.
            Button("Supprimer") {
                model.requestDeletion(of: row.id)
            }
            .tint(.red)
        }
        .contextMenu {
            Button("Supprimer", role: .destructive) {
                model.requestDeletion(of: row.id)
            }
        }
        .accessibilityAction(named: Text("Supprimer")) {
            model.requestDeletion(of: row.id)
        }
    }
}

/// Contenu d'une ligne : un seul élément VoiceOver (« Terminée, 12 mars, vainqueur Alice… »).
private struct FinishedGameRowContent: View {
    let row: FinishedGameRow

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    Text(row.date, format: .dateTime.day().month(.abbreviated).year().hour().minute().locale(Theme.locale))
                        .font(.headline)
                    StatusTag(kind: row.kind)
                }
                if row.isReadable {
                    Text(playersText)
                        .font(Theme.Typography.detail)
                        .foregroundStyle(.secondary)
                    if let winnersText {
                        Label(winnersText, systemImage: Theme.Symbol.leader)
                            .font(Theme.Typography.detail)
                    }
                    Text(roundsText)
                        .font(Theme.Typography.detail)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Les données de cette partie sont illisibles. Vous pouvez la supprimer.")
                        .font(Theme.Typography.detail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.Size.minTapTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var playersText: String {
        row.playerNames.formatted(.list(type: .and, width: .standard).locale(Theme.locale))
    }

    private var winnersText: String? {
        guard row.kind == .finished, !row.winnerNames.isEmpty else { return nil }
        let names = row.winnerNames.formatted(.list(type: .and, width: .standard).locale(Theme.locale))
        return row.hasCoWinners
            ? String(localized: "Co-vainqueurs\u{00A0}: \(names)")
            : String(localized: "Vainqueur\u{00A0}: \(names)")
    }

    private var roundsText: String {
        row.roundCount <= 1
            ? String(localized: "\(row.roundCount) manche")
            : String(localized: "\(row.roundCount) manches")
    }
}

/// Étiquette de statut : texte + symbole, jamais la couleur seule.
private struct StatusTag: View {
    let kind: FinishedGameRow.Kind

    var body: some View {
        // Texte en `.primary` (contraste) ; la couleur d'alerte ne porte que l'icône.
        Label {
            Text(title).foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(kind == .finished ? Color.primary : Theme.Palette.warning)
        }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Palette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
    }

    private var title: LocalizedStringKey {
        switch kind {
        case .finished: "Terminée"
        case .interrupted: "Interrompue"
        case .unreadable: "Illisible"
        }
    }

    private var symbol: String {
        switch kind {
        case .finished: "flag.checkered"
        case .interrupted: "pause.circle"
        case .unreadable: Theme.Symbol.warning
        }
    }
}

#if DEBUG
#Preview("Parties terminées") {
    NavigationStack {
        FinishedGamesView()
    }
    .previewEnvironment(.withHistory)
}

#Preview("Vide, sombre") {
    NavigationStack {
        FinishedGamesView()
    }
    .previewEnvironment()
    .preferredColorScheme(.dark)
}

#Preview("XXL") {
    NavigationStack {
        FinishedGamesView()
    }
    .previewEnvironment(.withHistory)
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
