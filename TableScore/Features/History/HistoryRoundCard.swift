import SwiftUI

/// Contenu d'une manche de l'historique : en-tête, clôturant et verdict, puis brut / retenu /
/// cumul par joueur dans l'ordre d'affichage. Aucune valeur n'est calculée ici.
///
/// Tailles d'accessibilité : la grille devient une liste empilée (pas de miniaturisation).
/// La lecture VoiceOver est fournie par l'appelant (`RoundRow.accessibilityLabel`).
struct HistoryRoundCard: View {
    let row: HistoryModel.RoundRow
    let showsDisclosure: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header
            closerLine
            if dynamicTypeSize.isAccessibilitySize {
                stackedPlayers
            } else {
                playerGrid
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: En-tête

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: "Manche \(row.index)")
                    .font(.headline)
                Spacer(minLength: Theme.Spacing.s)
                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            if row.isCorrected || row.isEndingRound || row.isAfterGameEnd {
                tags
            }
        }
    }

    private var tags: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Theme.Spacing.xs))
            : AnyLayout(HStackLayout(spacing: Theme.Spacing.m))
        return layout {
            if row.isCorrected {
                Label("Corrigée", systemImage: "pencil")
                    .foregroundStyle(.secondary)
            }
            if row.isEndingRound {
                Label("Fin de partie", systemImage: "flag.checkered.2.crossed")
                    .foregroundStyle(.secondary)
            }
            if row.isAfterGameEnd {
                Label {
                    Text("Jouée après la fin")
                } icon: {
                    Image(systemName: Theme.Symbol.warning)
                        .foregroundStyle(Theme.Palette.warning)
                }
            }
        }
        .font(.footnote)
    }

    // MARK: Clôturant

    private var closerLine: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label {
                Text(verbatim: "\(row.closerName) a terminé")
            } icon: {
                Image(systemName: Theme.Symbol.closer)
            }
            .font(Theme.Typography.detail.weight(.semibold))
            if row.isCloserDoubled {
                Label {
                    Text("×2 Doublé").bold()
                } icon: {
                    Image(systemName: Theme.Symbol.doubled)
                        .foregroundStyle(Theme.Palette.doubled)
                }
                .font(Theme.Typography.detail)
            }
            Text(verbatim: row.displayedCloserNote)
                .font(Theme.Typography.detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Joueurs

    private var playerGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.xs) {
            GridRow {
                // `Group` : les modificateurs s'appliquent à chaque cellule, la ligne reste une `GridRow`.
                Group {
                    Text("Joueur")
                    Text("Brut").gridColumnAlignment(.trailing)
                    Text("Retenu").gridColumnAlignment(.trailing)
                    Text("Total").gridColumnAlignment(.trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            ForEach(row.players) { player in
                GridRow {
                    playerName(player)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verbatim: ScoreFormat.display(player.rawScore))
                        .foregroundStyle(.secondary)
                    retainedScore(player)
                    Text(verbatim: total(player))
                        .fontWeight(.semibold)
                }
            }
        }
        .font(.body.monospacedDigit())
    }

    private var stackedPlayers: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(row.players) { player in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    playerName(player)
                    HStack(spacing: Theme.Spacing.xs) {
                        if player.isDoubled {
                            Image(systemName: Theme.Symbol.doubled)
                                .foregroundStyle(Theme.Palette.doubled)
                        }
                        Text(verbatim: "brut \(ScoreFormat.display(player.rawScore)) · retenu "
                            + "\(ScoreFormat.display(player.effectiveScore)) · total \(total(player))")
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Theme.Typography.detail)
                }
            }
        }
    }

    private func playerName(_ player: HistoryModel.PlayerLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            if player.isClosing {
                Image(systemName: Theme.Symbol.closer)
                    .font(.footnote)
            }
            Text(verbatim: player.name)
                .lineLimit(2)
                .fontWeight(player.isClosing ? .semibold : .regular)
        }
    }

    private func retainedScore(_ player: HistoryModel.PlayerLine) -> some View {
        HStack(spacing: 2) {
            if player.isDoubled {
                Image(systemName: Theme.Symbol.doubled)
                    .font(.footnote)
                    .foregroundStyle(Theme.Palette.doubled)
            }
            Text(verbatim: ScoreFormat.display(player.effectiveScore))
                .fontWeight(player.isDoubled ? .bold : .regular)
        }
    }

    private func total(_ player: HistoryModel.PlayerLine) -> String {
        player.totalAfterRound.map(ScoreFormat.display) ?? "—"
    }
}
