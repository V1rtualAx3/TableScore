import Accessibility
import SwiftUI
import TableScoreKit

/// Grille finale d'**un** joueur en mode cartes (cahier §3.3) : 3 rangées × 4 colonnes
/// verticales, bascule « Colonne retirée » au-dessus de chaque colonne, total brut en direct.
///
/// Aide au décompte final uniquement (aucune simulation de partie). Toute valeur affichée vient de
/// `CardGridPresentation`, elle-même dérivée de `CardGrid.evaluate()` (Kit) : la grille liée est
/// l'unique source de vérité, l'éditeur n'en garde aucune copie.
///
/// Mise en page : `CardGridColumnsLayout` (4 colonnes, ou 2 × 2 en tailles d'accessibilité ;
/// jamais de défilement horizontal). Le prénom n'est pas affiché en titre (responsabilité du
/// conteneur). Tous les boutons ont un style explicite : l'éditeur peut être placé dans une ligne
/// de `Form`/`List` sans que la ligne entière ne réagisse.
///
/// `onBeginEditing` est appelé à l'ouverture du sélecteur de valeur (ex. retirer le focus clavier).
struct CardGridEditor: View {
    @Binding private var grid: CardGrid
    private let playerName: String
    private let position: Int
    private let onBeginEditing: () -> Void

    /// Case en cours de saisie (feuille du sélecteur ouverte).
    @State private var selectedCell: CardGridPresentation.CellPosition?
    @State private var isPickerPresented = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        grid: Binding<CardGrid>,
        playerName: String,
        position: Int,
        onBeginEditing: @escaping () -> Void = {}
    ) {
        _grid = grid
        self.playerName = playerName
        self.position = position
        self.onBeginEditing = onBeginEditing
    }

    var body: some View {
        let presentation = CardGridPresentation(grid: grid, playerName: playerName, position: position)
        let highlighted = isPickerPresented ? selectedCell : nil
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            CardGridColumnsLayout { index in
                CardGridColumnView(
                    column: presentation.columns[index],
                    selectedCell: highlighted,
                    onSelect: { select($0) },
                    onToggleRemoved: { toggleRemoved(column: $0) }
                )
            }
            if !presentation.statusMessages.isEmpty {
                CardGridStatusMessages(messages: presentation.statusMessages)
            }
            CardGridTotalRow(presentation: presentation)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "Grille \(VerdictText.ofName(playerName))"))
        .sheet(isPresented: $isPickerPresented, onDismiss: { selectedCell = nil }) {
            pickerSheet
        }
    }

    @ViewBuilder
    private var pickerSheet: some View {
        if let cell = selectedCell {
            CardValuePicker(
                playerName: playerName,
                cellPosition: cell,
                currentValue: grid.columns[cell.column][cell.row],
                onPick: { pick($0, at: cell) },
                onRemoveColumn: { removeColumnFromPicker(at: cell) },
                onDone: { isPickerPresented = false }
            )
        }
    }

    // MARK: Actions

    private func select(_ cell: CardGridPresentation.CellPosition) {
        selectedCell = cell
        if !isPickerPresented {
            onBeginEditing()
            isPickerPresented = true
        }
    }

    /// Bascule de la grille. Si la colonne de la case en cours est retirée, la saisie avance.
    private func toggleRemoved(column index: Int) {
        let isRemoving = !grid.columns[index].isMarkedRemoved
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            // Indice issu de la présentation (0..<4) : l'erreur de position est impossible.
            _ = try? grid.setColumnRemoved(isRemoving, column: index)
        }
        if isRemoving, isPickerPresented, let cell = selectedCell, cell.column == index {
            move(to: CardGridPresentation.nextEmptyCell(in: grid, after: cell))
        }
    }

    /// Affecte la valeur, annonce, puis passe à la case vide suivante ; ferme la feuille quand il
    /// n'en reste aucune (correction d'une grille complète : un toucher). « Effacer » reste sur place.
    private func pick(_ value: Int?, at cell: CardGridPresentation.CellPosition) {
        let before = grid
        // Valeur issue de `CardGrid.cardValues` et position de la présentation : jamais invalides.
        _ = try? grid.setCard(value, column: cell.column, row: cell.row)
        guard let value else {
            announce("Case vide")
            return
        }
        let next = CardGridPresentation.nextEmptyCell(in: grid, after: cell)
        announce(CardGridPresentation.pickAnnouncement(
            value: value, column: cell.column, before: before, after: grid, next: next
        ))
        move(to: next)
    }

    private func removeColumnFromPicker(at cell: CardGridPresentation.CellPosition) {
        _ = try? grid.setColumnRemoved(true, column: cell.column)
        let next = CardGridPresentation.nextEmptyCell(in: grid, after: cell)
        announce(CardGridPresentation.removalAnnouncement(column: cell.column, grid: grid, next: next))
        move(to: next)
    }

    private func move(to next: CardGridPresentation.CellPosition?) {
        if let next {
            selectedCell = next
        } else {
            isPickerPresented = false
        }
    }

    /// Priorité haute : l'annonce n'est pas interrompue par la mise à jour de la feuille.
    private func announce(_ text: String) {
        var message = AttributedString(text)
        message.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - Sous-vues (corps courts : temps de compilation)

/// Une colonne verticale : titre, bascule « Colonne retirée » (au-dessus), 3 cases, sous-total.
private struct CardGridColumnView: View {
    let column: CardGridPresentation.Column
    let selectedCell: CardGridPresentation.CellPosition?
    let onSelect: (CardGridPresentation.CellPosition) -> Void
    let onToggleRemoved: (Int) -> Void

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Text(verbatim: column.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityHidden(true) // déjà dans le libellé de chaque case
            CardColumnRemovalToggle(column: column, onToggle: { onToggleRemoved(column.index) })
            ForEach(column.cells) { cell in
                CardCellButton(
                    cell: cell,
                    isSelected: selectedCell == cell.position,
                    onSelect: { onSelect(cell.position) }
                )
            }
            CardColumnSubtotal(column: column)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Case : « — » et contour pointillé si vide ; fond plein dès qu'une valeur (y compris 0) est
/// saisie. Colonne non comptée : valeur barrée, couleur secondaire et mention VoiceOver.
private struct CardCellButton: View {
    let cell: CardGridPresentation.Cell
    let isSelected: Bool
    let onSelect: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .title2) private var cellHeight: CGFloat = 52

    var body: some View {
        Button(action: onSelect) {
            Text(verbatim: cell.displayText)
                .font(Theme.Typography.entryScore)
                .monospacedDigit()
                .lineLimit(1)
                .strikethrough(cell.isExcluded && cell.value != nil)
                .foregroundStyle(textStyle)
                .frame(maxWidth: .infinity, minHeight: max(cellHeight, Theme.Size.minTapTarget))
                .background { background }
                .overlay { selectionRing }
                .contentShape(RoundedRectangle(cornerRadius: Theme.Spacing.s))
        }
        .buttonStyle(.plain)
        .disabled(!cell.isEditable)
        .accessibilityLabel(Text(verbatim: cell.accessibilityLabel))
        .accessibilityValue(Text(verbatim: cell.accessibilityValue))
        .accessibilityHint(cell.isEditable ? Text("Choisir la valeur de la carte") : Text("Rétablir la colonne pour modifier"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(cell.accessibilityIdentifier)
    }

    private var isIncreasedContrast: Bool { contrast == .increased }

    private var textStyle: Color {
        if cell.value == nil { return isIncreasedContrast ? .primary : .secondary }
        if cell.isExcluded { return isIncreasedContrast ? .primary : .secondary }
        return .primary
    }

    @ViewBuilder
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Spacing.s)
        if cell.value == nil {
            shape.strokeBorder(
                isIncreasedContrast ? Color.primary : Color.secondary,
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
        } else {
            shape.fill(Color(uiColor: .tertiarySystemFill))
        }
    }

    @ViewBuilder
    private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: Theme.Spacing.s)
                .strokeBorder(Theme.Palette.accent, lineWidth: 3)
        }
    }
}

/// Bascule « Colonne retirée » : la colonne compte 0, ses valeurs sont conservées (re-basculer
/// les restaure). État porté par le symbole (case cochée), pas seulement la couleur ;
/// VoiceOver : « Retirer la colonne 2, activé/désactivé, bouton bascule ».
private struct CardColumnRemovalToggle: View {
    let column: CardGridPresentation.Column
    let onToggle: () -> Void

    var body: some View {
        let isOn = column.isMarkedRemoved
        Button(action: onToggle) {
            VStack(spacing: Theme.Spacing.xs) {
                Image(systemName: isOn ? "checkmark.square.fill" : "square")
                    .font(.body)
                Text(verbatim: CardGridPresentation.removeColumnTitle)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(isOn ? Theme.Palette.accent : Color.primary)
            .padding(Theme.Spacing.xs)
            .frame(maxWidth: .infinity, minHeight: Theme.Size.minTapTarget)
            .background {
                RoundedRectangle(cornerRadius: Theme.Spacing.s)
                    .fill(isOn ? Theme.Palette.accent.opacity(0.15) : Color(uiColor: .tertiarySystemFill))
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Spacing.s))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: column.removeToggleAccessibilityLabel))
        .accessibilityValue(isOn ? Text("activé") : Text("désactivé"))
        .accessibilityHint(Text("La colonne compte 0. Les valeurs saisies sont conservées."))
        .accessibilityAddTraits(.isToggle)
        .accessibilityIdentifier(column.removeToggleIdentifier)
    }
}

private struct CardColumnSubtotal: View {
    let column: CardGridPresentation.Column

    var body: some View {
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
}

private struct CardGridStatusMessages: View {
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(messages, id: \.self) { message in
                Label {
                    Text(verbatim: message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "nosign")
                        .foregroundStyle(.secondary)
                }
                .font(Theme.Typography.detail)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// « Total brut » + état (cartes à saisir / grille complète, symbole + texte) + total en grand.
private struct CardGridTotalRow: View {
    let presentation: CardGridPresentation

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
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

    private var caption: some View {
        let isComplete = presentation.isComplete
        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Total brut")
                .font(.headline)
            Label {
                Text(verbatim: presentation.completionText)
            } icon: {
                Image(systemName: isComplete ? Theme.Symbol.selected : Theme.Symbol.warning)
                    .foregroundStyle(isComplete ? Theme.Palette.accent : Theme.Palette.warning)
            }
            .font(Theme.Typography.detail)
            .foregroundStyle(isComplete ? Color.secondary : Color.primary)
        }
    }
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
