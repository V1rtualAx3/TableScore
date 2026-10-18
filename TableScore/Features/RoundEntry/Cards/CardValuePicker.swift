import SwiftUI
import TableScoreKit

/// Sélecteur de valeur d'une carte, présenté en feuille basse par `CardGridEditor`.
///
/// Décision : pavé de 15 boutons (−2…12, 5 × 3 ; 3 colonnes en tailles d'accessibilité) dans
/// une feuille système plutôt qu'un `Menu` ou un popover :
/// - **un seul toucher par carte** : après un choix, l'éditeur passe à la case vide suivante
///   (colonne par colonne) sans refermer la feuille ; fermeture automatique en fin de grille ;
/// - feuille en bas de l'écran = **zone du pouce** (une main) ; hauteur mesurée pour que pavé et
///   actions tiennent sans défilement (iPhone SE compris), la grille restant touchable au-dessus ;
/// - boutons natifs ≥ 44 pt, libellés VoiceOver « moins 2 », aucune saisie invalide possible ;
/// - « Effacer » remet la case à vide (distincte de 0) ; « Colonne N retirée » marque la colonne
///   de la case courante retirée sans quitter la saisie.
struct CardValuePicker: View {
    let playerName: String
    let cellPosition: CardGridPresentation.CellPosition
    /// Valeur actuelle de la case (`nil` = vide).
    let currentValue: Int?
    /// Valeur choisie (`nil` = effacer).
    let onPick: (Int?) -> Void
    /// Marque retirée la colonne de la case courante.
    let onRemoveColumn: () -> Void
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Hauteur mesurée du contenu (estimation sûre avant la première mesure).
    @State private var contentHeight: CGFloat = 320

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                CardValuePickerHeader(
                    title: CardGridPresentation.pickerTitle(playerName: playerName, position: cellPosition),
                    onDone: onDone
                )
                CardValuePad(currentValue: currentValue, onPick: onPick)
                CardValuePickerActions(
                    column: cellPosition.column,
                    canClear: currentValue != nil,
                    onClear: { onPick(nil) },
                    onRemoveColumn: onRemoveColumn
                )
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                contentHeight = height.rounded(.up)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(detents)
        .presentationDragIndicator(.visible)
        .presentationBackgroundInteraction(backgroundInteraction)
    }

    /// Hauteur ajustée au contenu ; tailles d'accessibilité : plein écran (défilement autorisé).
    private var fittedDetent: PresentationDetent { .height(max(contentHeight, 200)) }

    private var detents: Set<PresentationDetent> {
        dynamicTypeSize.isAccessibilitySize ? [.large] : [fittedDetent, .large]
    }

    /// La grille reste touchable au-dessus de la feuille (changer de case sans la fermer).
    private var backgroundInteraction: PresentationBackgroundInteraction {
        dynamicTypeSize.isAccessibilitySize ? .automatic : .enabled(upThrough: fittedDetent)
    }
}

/// En-tête sur une ligne : « Alice · colonne 2, rangée 1 » et « OK ».
private struct CardValuePickerHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(verbatim: title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.s)
            // Cadre de 44 pt **dans** le libellé (zone touchable et cadre d'accessibilité) : posé
            // sur le bouton, il n'agrandissait que la mise en page (audit : zone touchable trop petite).
            Button(action: onDone) {
                Text("OK")
                    .fontWeight(.semibold)
                    .frame(minWidth: Theme.Size.minTapTarget, minHeight: Theme.Size.minTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.Cards.valuePickerDone)
        }
    }
}

/// Pavé des 15 valeurs −2…12. Valeur actuelle : style proéminent (fond plein, pas seulement une
/// teinte) **et** trait VoiceOver « sélectionné ».
private struct CardValuePad: View {
    let currentValue: Int?
    let onPick: (Int?) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let count = dynamicTypeSize.isAccessibilitySize ? 3 : 5
        let columns = Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.s), count: count)
        LazyVGrid(columns: columns, spacing: Theme.Spacing.s) {
            ForEach(Array(CardGrid.cardValues), id: \.self) { value in
                valueButton(value)
                    .accessibilityLabel(Text(verbatim: ScoreFormat.spoken(value)))
                    .accessibilityAddTraits(value == currentValue ? .isSelected : [])
                    .accessibilityIdentifier(AccessibilityID.Cards.valuePicker(value: value))
            }
        }
    }

    @ViewBuilder
    private func valueButton(_ value: Int) -> some View {
        if value == currentValue {
            Button {
                onPick(value)
            } label: {
                valueLabel(value)
                    .onAccentForeground()
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button {
                onPick(value)
            } label: {
                valueLabel(value)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Valeur sur une ligne : « −2 » à « 12 » tiennent toujours dans la case (pas de troncature).
    private func valueLabel(_ value: Int) -> some View {
        Text(verbatim: ScoreFormat.display(value))
            .font(Theme.Typography.entryScore)
            .monospacedDigit()
            .fixedSize()
            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            .contentShape(Rectangle())
    }
}

/// « Effacer » et « Colonne N retirée », sous le pavé.
private struct CardValuePickerActions: View {
    let column: Int
    let canClear: Bool
    let onClear: () -> Void
    let onRemoveColumn: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Theme.Spacing.s) { buttons }
        } else {
            HStack(spacing: Theme.Spacing.s) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button(action: onClear) {
            Label("Effacer", systemImage: "delete.left")
                .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
        }
        .buttonStyle(.bordered)
        .disabled(!canClear)
        .accessibilityLabel("Effacer la carte")
        .accessibilityIdentifier(AccessibilityID.Cards.valuePickerClear)

        Button(action: onRemoveColumn) {
            Label {
                Text(verbatim: CardGridPresentation.removeColumnFromPickerTitle(column: column))
            } icon: {
                Image(systemName: "square")
            }
            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
        }
        .buttonStyle(.bordered)
        // Libellé = texte visible (Contrôle vocal ; audit « texte potentiellement inaccessible ») ;
        // l'action est expliquée par l'indice.
        .accessibilityHint(Text(verbatim: "Retire la colonne \(column + 1)\u{00A0}: elle compte 0. Les valeurs saisies sont conservées."))
        .accessibilityIdentifier(AccessibilityID.Cards.valuePickerRemoveColumn)
    }
}

#if DEBUG
#Preview("Sélecteur de valeur") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            CardValuePicker(
                playerName: "Alice",
                cellPosition: .init(column: 1, row: 0),
                currentValue: 0,
                onPick: { _ in },
                onRemoveColumn: {},
                onDone: {}
            )
        }
}
#endif
