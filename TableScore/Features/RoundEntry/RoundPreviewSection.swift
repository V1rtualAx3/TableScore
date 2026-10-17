import SwiftUI

/// Aperçu **avant confirmation** (cahier §4.4) : score retenu de chaque joueur, raison du
/// doublement ou du non-doublement pour le clôturant, cumuls à venir. Toutes les valeurs
/// viennent de `ScoreEngine` (via `RoundEntryModel.RoundPreview`) ; ici, seulement l'affichage.
struct RoundPreviewSection: View {
    let preview: RoundEntryModel.RoundPreview

    var body: some View {
        Section {
            ForEach(preview.lines) { line in
                RoundPreviewRow(line: line)
            }
        } header: {
            Text("Aperçu avant enregistrement")
        } footer: {
            if !notes.isEmpty {
                Text(notes.joined(separator: "\n"))
            }
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if let endingIndex = preview.earlyEndRoundIndex {
            notes.append(
                "Cette correction termine la partie à la manche \(endingIndex)\u{00A0}: "
                    + "une confirmation sera demandée."
            )
        } else if preview.endsGameAtThisRound {
            notes.append(
                "Cette manche termine la partie\u{00A0}: un total atteint \(preview.targetScore) points. "
                    + "Le plus petit total gagne."
            )
        }
        if preview.recomputesLaterRounds {
            notes.append("Les manches suivantes seront recalculées.")
        }
        return notes
    }
}

private struct RoundPreviewRow: View {
    let line: RoundEntryModel.PreviewLine

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(line.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                if line.isCloser {
                    Image(systemName: Theme.Symbol.closer)
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: Theme.Spacing.s)
                Text(ScoreFormat.delta(line.roundScore))
                    .font(Theme.Typography.entryScore)
                    .bold()
            }
            if let description = line.closerDescription {
                Text(description.detail)
                    .font(Theme.Typography.detail)
                    .fixedSize(horizontal: false, vertical: true)
                if line.isDoubled {
                    RoundEntryDoubledBadge()
                }
            }
            Text(line.totalText)
                .font(Theme.Typography.detail)
                .monospacedDigit()
                .foregroundStyle(Color.secondary)
        }
        .padding(.vertical, Theme.Spacing.xs)
        // Une seule annonce VoiceOver par joueur, sans flèche ni signe typographique ambigu.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.spokenSummary)
        .accessibilityIdentifier(AccessibilityID.Round.preview(position: line.position))
    }
}

/// Badge « ×2 Doublé » : symbole coloré + texte (la couleur n'est jamais seule porteuse du sens).
private struct RoundEntryDoubledBadge: View {
    var body: some View {
        Label {
            Text("×2 Doublé")
                .bold()
        } icon: {
            Image(systemName: Theme.Symbol.doubled)
                .foregroundStyle(Theme.Palette.doubled)
        }
        .font(.caption)
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Palette.doubled.opacity(0.15), in: Capsule())
    }
}
