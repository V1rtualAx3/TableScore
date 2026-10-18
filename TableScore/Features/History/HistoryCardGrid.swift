import SwiftUI
import TableScoreKit

/// Feuille de consultation des grilles d'une manche (lecture seule) : une section par joueur saisi
/// en mode « Cartes ». Corriger reste l'affaire de la feuille de correction (toucher la manche).
struct HistoryCardsSheet: View {
    let row: HistoryModel.RoundRow

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(row.cardPlayers) { player in
                    if let grid = player.cardGrid {
                        Section {
                            HistoryCardGridView(grid: grid, playerName: player.name, position: player.position)
                        } header: {
                            Text(verbatim: player.name)
                                .textCase(nil)
                                .foregroundStyle(Theme.Palette.secondaryText)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(Text(verbatim: "Cartes · manche \(row.index)"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Grille finale enregistrée, en lecture seule : 4 colonnes verticales de 3 cartes, résultat de
/// chaque colonne (texte, jamais la couleur seule), explications et total.
///
/// Textes, libellés VoiceOver et disposition (4 colonnes, 2 × 2 en tailles d'accessibilité) :
/// `CardGridPresentation` et `CardGridColumnsLayout`, partagés avec l'éditeur ; valeurs dérivées
/// de `CardGrid.evaluate()` du Kit, aucun calcul ici. VoiceOver : un élément par colonne
/// (« Colonne 1, 0 point, colonne non comptée », valeur « 7, 7, 7 »), les explications affichées,
/// puis le total.
struct HistoryCardGridView: View {
    let grid: CardGrid
    let playerName: String
    let position: Int

    @ScaledMetric(relativeTo: .title3) private var cellHeight: CGFloat = 40

    var body: some View {
        let presentation = CardGridPresentation(grid: grid, playerName: playerName, position: position)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            CardGridColumnsLayout { index in
                columnView(presentation.columns[index])
            }
            ForEach(presentation.statusMessages, id: \.self) { message in
                Label {
                    Text(verbatim: message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "nosign")
                }
                .font(Theme.Typography.detail)
                .foregroundStyle(Theme.Palette.secondaryText)
                // Texte visible donc exposé (un texte masqué est signalé par l'audit), lu d'un bloc.
                .accessibilityElement(children: .combine)
            }
            HStack(alignment: .firstTextBaseline) {
                Text("Total brut")
                    .font(.headline)
                Spacer(minLength: Theme.Spacing.s)
                Text(verbatim: presentation.totalText)
                    .font(Theme.Typography.entryScore.bold())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: presentation.totalAccessibilityLabel))
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func columnView(_ column: CardGridPresentation.Column) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(verbatim: column.title)
                .font(.caption)
                .foregroundStyle(Theme.Palette.secondaryText)
            ForEach(column.cells) { cell in
                cellView(cell)
            }
            Text(verbatim: column.subtotalText)
                .font(.subheadline.monospacedDigit().weight(.semibold))
            if let shortStatus = column.shortStatus {
                Text(verbatim: shortStatus)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: column.subtotalAccessibilityLabel))
        .accessibilityValue(Text(verbatim: column.cells
            .map { CardGridPresentation.spokenCardValue($0.value) }
            .joined(separator: ", ")))
    }

    private func cellView(_ cell: CardGridPresentation.Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Spacing.s)
        // « −2 » à « 12 » ou « — » : une ligne, taille idéale (jamais tronquée).
        return Text(verbatim: cell.displayText)
            .font(Theme.Typography.entryScore)
            // Colonne non comptée : valeur barrée (texte secondaire, contraste conservé), jamais effacée.
            .strikethrough(cell.isExcluded && cell.value != nil)
            .foregroundStyle(cell.isExcluded || cell.value == nil ? Theme.Palette.secondaryText : Color.primary)
            .fixedSize()
            .frame(maxWidth: .infinity, minHeight: cellHeight)
            .background(shape.fill(Color(.tertiarySystemFill)))
    }
}

#if DEBUG
#Preview("Grille en lecture seule") {
    let grid = (try? CardGrid(
        rows: [[7, 1, nil, -2], [7, 2, nil, -2], [7, 3, nil, -2]],
        removedColumns: [2]
    )) ?? CardGrid()
    return List {
        HistoryCardGridView(grid: grid, playerName: "Alice", position: 0)
    }
}
#endif
