import SwiftUI
import TableScoreKit

/// Grille finale d'**un** joueur en mode cartes (cahier §3.3) : 3 rangées × 4 colonnes
/// verticales, bouton « Colonne retirée » par colonne, total brut en direct.
///
/// Aide au décompte final uniquement (aucune simulation de partie). Toute valeur affichée vient de
/// `CardGridPresentation`, elle-même dérivée de `CardGrid.evaluate()` (Kit) : la grille liée est
/// l'unique source de vérité, l'éditeur n'en garde aucune copie.
///
/// Mise en page : 4 colonnes côte à côte ; en tailles d'accessibilité, 2 × 2 colonnes (chaque
/// colonne reste verticale, titrée « Colonne n ») — jamais de défilement horizontal.
/// Le prénom n'est pas affiché en titre (responsabilité du conteneur) ; il sert aux libellés
/// VoiceOver et à l'en-tête du sélecteur. Tous les boutons ont un style explicite : l'éditeur
/// peut être placé dans une ligne de `Form`/`List` sans que la ligne entière ne réagisse.
struct CardGridEditor: View {
    @Binding private var grid: CardGrid
    private let playerName: String
    private let position: Int

    /// Case en cours de saisie (feuille du sélecteur ouverte).
    @State private var selectedCell: CardGridPresentation.CellPosition?
    @State private var isPickerPresented = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title2) private var cellHeight: CGFloat = 52

    init(grid: Binding<CardGrid>, playerName: String, position: Int) {
        _grid = grid
        self.playerName = playerName
        self.position = position
    }

    var body: some View {
        let presentation = CardGridPresentation(grid: grid, playerName: playerName, position: position)
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            columnsLayout(presentation)
            if !presentation.statusMessages.isEmpty {
                statusMessages(presentation)
            }
            totalRow(presentation)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Grille \(VerdictText.ofName(playerName))"))
        .sheet(isPresented: $isPickerPresented, onDismiss: { selectedCell = nil }) {
            pickerSheet
        }
    }

    // MARK: Colonnes

    @ViewBuilder
    private func columnsLayout(_ presentation: CardGridPresentation) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            // 2 × 2 : colonnes 1-2 puis 3-4, chacune toujours verticale.
            VStack(spacing: Theme.Spacing.l) {
                ForEach([0, 2], id: \.self) { first in
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        ForEach(presentation.columns[first..<(first + 2)]) { column in
                            columnView(column)
                        }
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                ForEach(presentation.columns) { column in
                    columnView(column)
                }
            }
        }
    }

    private func columnView(_ column: CardGridPresentation.Column) -> some View {
        VStack(spacing: Theme.Spacing.s) {
            Text(verbatim: column.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true) // déjà dans le libellé de chaque case

            ForEach(column.cells) { cell in
                cellButton(cell)
            }

            subtotal(column)
            removeToggle(column)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private func cellButton(_ cell: CardGridPresentation.Cell) -> some View {
        let isSelected = isPickerPresented && selectedCell == cell.position
        let shape = RoundedRectangle(cornerRadius: Theme.Spacing.s)
        return Button {
            selectedCell = cell.position
            isPickerPresented = true
        } label: {
            Text(verbatim: cell.displayText)
                .font(Theme.Typography.entryScore)
                .monospacedDigit()
                .lineLimit(1)
                // Retrait (manuel ou triplet) : valeur barrée et estompée, jamais effacée.
                .strikethrough(cell.isExcluded && cell.value != nil)
                .foregroundStyle(cell.value == nil ? Color.secondary : Color.primary)
                .frame(maxWidth: .infinity, minHeight: max(cellHeight, Theme.Size.minTapTarget))
                .background {
                    // Case vide : contour pointillé et « — » ; case renseignée (y compris 0) : fond plein.
                    if cell.value == nil {
                        shape.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    } else {
                        shape.fill(Color(.tertiarySystemFill))
                    }
                }
                .overlay {
                    if isSelected {
                        shape.strokeBorder(Theme.Palette.accent, lineWidth: 3)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!cell.isEditable)
        .opacity(cell.isExcluded ? 0.5 : 1)
        .accessibilityLabel(Text(verbatim: cell.accessibilityLabel))
        .accessibilityValue(Text(verbatim: cell.accessibilityValue))
        .accessibilityHint(cell.isEditable ? Text("Choisir la valeur de la carte") : Text("Rétablir la colonne pour modifier"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(cell.accessibilityIdentifier)
    }

    private func subtotal(_ column: CardGridPresentation.Column) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(verbatim: column.subtotalText)
                .font(.headline)
                .monospacedDigit()
            if let shortStatus = column.shortStatus {
                Text(verbatim: shortStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: column.subtotalAccessibilityLabel))
    }

    /// Bascule « Colonne retirée » : la colonne compte 0, ses valeurs sont conservées (re-basculer
    /// les restaure). État porté par le symbole (case cochée) et le texte, pas seulement la couleur.
    private func removeToggle(_ column: CardGridPresentation.Column) -> some View {
        let isOn = column.isMarkedRemoved
        let index = column.index
        let shape = RoundedRectangle(cornerRadius: Theme.Spacing.s)
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                // Indice issu de la présentation (0..<4) : l'erreur de position est impossible.
                _ = try? grid.setColumnRemoved(!isOn, column: index)
            }
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                Text(CardGridPresentation.removeColumnTitle)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isOn ? Theme.Palette.accent : Color.primary)
            .padding(.vertical, Theme.Spacing.xs)
            .padding(.horizontal, Theme.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            .background {
                shape.fill(isOn ? Theme.Palette.accent.opacity(0.15) : Color(.tertiarySystemFill))
            }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: column.removeToggleAccessibilityLabel))
        .accessibilityValue(isOn ? Text("activé") : Text("désactivé"))
        .accessibilityHint(Text("La colonne compte 0. Les valeurs saisies sont conservées."))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(column.removeToggleIdentifier)
    }

    // MARK: Messages et total

    private func statusMessages(_ presentation: CardGridPresentation) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(presentation.statusMessages, id: \.self) { message in
                Label {
                    Text(verbatim: message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: Self.excludedSymbol)
                        .foregroundStyle(.secondary)
                }
                .font(Theme.Typography.detail)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder
    private func totalRow(_ presentation: CardGridPresentation) -> some View {
        let caption = VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Total brut")
                .font(.headline)
            Label {
                Text(verbatim: presentation.completionText)
            } icon: {
                Image(systemName: presentation.isComplete ? Theme.Symbol.selected : Theme.Symbol.warning)
                    .foregroundStyle(presentation.isComplete ? Theme.Palette.accent : Theme.Palette.warning)
            }
            .font(Theme.Typography.detail)
            .foregroundStyle(presentation.isComplete ? Color.secondary : Color.primary)
        }
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    caption
                    ScoreText(presentation.runningTotal)
                }
            } else {
                HStack(alignment: .center, spacing: Theme.Spacing.m) {
                    caption
                    Spacer(minLength: Theme.Spacing.s)
                    ScoreText(presentation.runningTotal)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: presentation.totalAccessibilityLabel))
        .accessibilityIdentifier(presentation.totalIdentifier)
    }

    // MARK: Sélecteur de valeur

    @ViewBuilder
    private var pickerSheet: some View {
        if let selectedCell {
            CardValuePicker(
                playerName: playerName,
                cellPosition: selectedCell,
                currentValue: grid.columns[selectedCell.column][selectedCell.row],
                onPick: { pick($0, at: selectedCell) },
                onDone: { isPickerPresented = false }
            )
            .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Affecte la valeur puis, si une valeur a été choisie, passe à la case vide suivante ; ferme
    /// la feuille quand il n'en reste aucune (correction d'une grille déjà complète : un toucher).
    /// « Effacer » reste sur la case.
    private func pick(_ value: Int?, at cell: CardGridPresentation.CellPosition) {
        // Valeur issue de `CardGrid.cardValues` et position de la présentation : jamais invalides.
        _ = try? grid.setCard(value, column: cell.column, row: cell.row)
        guard value != nil else { return }
        if let next = CardGridPresentation.nextEmptyCell(in: grid, after: cell) {
            selectedCell = next
            AccessibilityNotification.Announcement(CardGridPresentation.positionTitle(next)).post()
        } else {
            isPickerPresented = false
        }
    }

    private static let excludedSymbol = "nosign"
}

#if DEBUG
#Preview("Grille en cours") {
    @Previewable @State var grid = (try? CardGrid(
        rows: [
            [7, -2, 5, nil],
            [7, -2, 0, nil],
            [7, -2, nil, 3]
        ],
        removedColumns: []
    )) ?? CardGrid()
    ScrollView {
        CardGridEditor(grid: $grid, playerName: "Alice", position: 0)
            .padding()
    }
}

#Preview("Colonne retirée, grille complète") {
    @Previewable @State var grid = (try? CardGrid(
        rows: [
            [12, 4, 0, 1],
            [11, 4, 0, 2],
            [10, 4, 0, 3]
        ],
        removedColumns: [0]
    )) ?? CardGrid()
    Form {
        Section("Élodie") {
            CardGridEditor(grid: $grid, playerName: "Élodie", position: 1)
        }
    }
}

#Preview("Grille vide, grande police") {
    @Previewable @State var grid = CardGrid()
    ScrollView {
        CardGridEditor(grid: $grid, playerName: "Bob", position: 2)
            .padding()
    }
    .environment(\.dynamicTypeSize, .accessibility3)
}
#endif
