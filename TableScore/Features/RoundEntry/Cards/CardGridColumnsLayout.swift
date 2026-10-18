import SwiftUI
import TableScoreKit

/// Disposition des 4 colonnes verticales d'une grille, partagée par l'éditeur et l'historique.
///
/// - Tailles standard : 4 colonnes côte à côte.
/// - Tailles d'accessibilité : 2 × 2 (colonnes 1-2 puis 3-4), chaque colonne restant verticale.
///
/// Jamais de défilement horizontal. `column(index)` fournit la vue de la colonne `index` (0-based).
struct CardGridColumnsLayout<ColumnContent: View>: View {
    private let column: (Int) -> ColumnContent

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder column: @escaping (Int) -> ColumnContent) {
        self.column = column
    }

    /// Nombre de colonnes par rangée de disposition pour une taille de police donnée.
    static func columnsPerRow(for size: DynamicTypeSize) -> Int {
        size.isAccessibilitySize ? 2 : CardGrid.columnCount
    }

    var body: some View {
        let perRow = Self.columnsPerRow(for: dynamicTypeSize)
        VStack(spacing: Theme.Spacing.l) {
            ForEach(Array(stride(from: 0, to: CardGrid.columnCount, by: perRow)), id: \.self) { first in
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    ForEach(first..<min(first + perRow, CardGrid.columnCount), id: \.self) { index in
                        column(index)
                    }
                }
            }
        }
    }
}
