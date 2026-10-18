import SwiftUI
import TableScoreKit

/// Sélecteur de valeur d'une carte, présenté en feuille basse par `CardGridEditor`.
///
/// Décision : pavé de 15 boutons (−2…12, 5 × 3 ; 3 colonnes en tailles d'accessibilité) dans
/// une feuille système plutôt qu'un `Menu` ou un popover :
/// - **un seul toucher par carte** : après un choix, l'éditeur passe à la case vide suivante sans
///   refermer la feuille (12 touchers pour une grille) ;
/// - feuille en bas de l'écran = **zone du pouce** (une main), quelle que soit la position de la
///   case ; un `Menu` (liste verticale de 15 entrées) ou un popover ancré en haut de l'écran
///   imposent défilement ou déplacement de la main ;
/// - boutons natifs ≥ 44 pt, libellés VoiceOver « moins 2 », pas de clavier texte : seules les
///   valeurs −2…12 sont proposées (aucune saisie invalide possible) ;
/// - « Effacer » remet la case à vide (distincte de 0).
struct CardValuePicker: View {
    let playerName: String
    let cellPosition: CardGridPresentation.CellPosition
    /// Valeur actuelle de la case (`nil` = vide).
    let currentValue: Int?
    /// Valeur choisie (`nil` = effacer).
    let onPick: (Int?) -> Void
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .title2) private var buttonHeight: CGFloat = 52

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                header
                valueGrid
                actions
            }
            .padding(Theme.Spacing.l)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(verbatim: playerName)
                .font(Theme.Typography.playerName)
                .lineLimit(2)
            Text(verbatim: CardGridPresentation.positionTitle(cellPosition))
                .font(.headline)
            Text(verbatim: currentValueText)
                .font(Theme.Typography.detail)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var currentValueText: String {
        guard let currentValue else { return "Case vide" }
        return "Valeur actuelle\(CardGridPresentation.nbsp): \(ScoreFormat.display(currentValue))"
    }

    private var valueGrid: some View {
        let count = dynamicTypeSize.isAccessibilitySize ? 3 : 5
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: count)
        return LazyVGrid(columns: columns, spacing: Theme.Spacing.s) {
            ForEach(Array(CardGrid.cardValues), id: \.self) { value in
                valueButton(value)
                    .accessibilityLabel(Text(verbatim: ScoreFormat.spoken(value)))
                    .accessibilityAddTraits(value == currentValue ? .isSelected : [])
                    .accessibilityIdentifier(AccessibilityID.Cards.valuePicker(value: value))
            }
        }
    }

    /// Valeur actuelle : style proéminent **et** trait VoiceOver « sélectionné » ; l'en-tête la
    /// rappelle aussi en texte (information jamais portée par la seule couleur).
    @ViewBuilder
    private func valueButton(_ value: Int) -> some View {
        let button = Button {
            onPick(value)
        } label: {
            Text(verbatim: ScoreFormat.display(value))
                .font(Theme.Typography.entryScore)
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: max(buttonHeight, Theme.Size.minTapTarget))
                .contentShape(Rectangle())
        }
        if value == currentValue {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button {
                onPick(nil)
            } label: {
                Label("Effacer", systemImage: "delete.left")
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            }
            .buttonStyle(.bordered)
            .disabled(currentValue == nil)
            .accessibilityLabel("Effacer la carte")
            .accessibilityIdentifier(AccessibilityID.Cards.valuePickerClear)

            Button {
                onDone()
            } label: {
                Text("OK")
                    .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier(AccessibilityID.Cards.valuePickerDone)
        }
    }
}

#if DEBUG
#Preview("Sélecteur de valeur") {
    CardValuePicker(
        playerName: "Alice",
        cellPosition: .init(column: 1, row: 0),
        currentValue: 0,
        onPick: { _ in },
        onDone: {}
    )
}
#endif
